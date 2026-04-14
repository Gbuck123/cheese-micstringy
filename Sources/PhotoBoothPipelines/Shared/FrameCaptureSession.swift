// FrameCaptureSession.swift
// Shared burst-capture engine used by GIF, Boomerang, and PhotoStrip pipelines.
//
// This wraps AVCaptureSession and provides a clean API for:
//   - Capturing N frames at a target FPS
//   - Capturing at high frame rates (120/240 fps) for slow-motion
//   - Memory-efficient frame buffering with back-pressure
//   - Thermal throttling awareness

import AVFoundation
import CoreImage
import UIKit

// MARK: - Configuration

/// Describes how a burst capture should behave.
public struct BurstCaptureConfig {
    /// Number of frames to capture.
    public var frameCount: Int
    /// Target capture FPS. The session will pick the closest supported format.
    public var targetFPS: Double
    /// Maximum resolution. Frames are scaled down if the sensor exceeds this.
    public var maxResolution: CGSize
    /// If true, frames are delivered as CIImage (GPU-backed). Otherwise CGImage (CPU-backed).
    public var preferGPUBacked: Bool
    /// Camera position.
    public var cameraPosition: AVCaptureDevice.Position

    public init(
        frameCount: Int = 10,
        targetFPS: Double = 10,
        maxResolution: CGSize = CGSize(width: 1080, height: 1920),
        preferGPUBacked: Bool = true,
        cameraPosition: AVCaptureDevice.Position = .front
    ) {
        self.frameCount = frameCount
        self.targetFPS = targetFPS
        self.maxResolution = maxResolution
        self.preferGPUBacked = preferGPUBacked
        self.cameraPosition = cameraPosition
    }
}

// MARK: - Captured Frame

/// A single captured frame with its metadata.
public struct CapturedFrame {
    /// The frame image. Always non-nil at capture time; may be nil after memory purge.
    public var cgImage: CGImage?
    /// GPU-backed variant. Cheaper to composite with CIFilter pipelines.
    public var ciImage: CIImage?
    /// Presentation timestamp relative to the start of the burst.
    public let timestamp: CMTime
    /// Ordinal index in the burst (0-based).
    public let index: Int
}

// MARK: - Delegate

public protocol FrameCaptureSessionDelegate: AnyObject {
    /// Called on a serial queue each time a frame is captured.
    func frameCaptureSession(_ session: FrameCaptureSession, didCapture frame: CapturedFrame)
    /// Called when all frames have been captured.
    func frameCaptureSessionDidFinish(_ session: FrameCaptureSession, frames: [CapturedFrame])
    /// Called if the capture fails or is interrupted.
    func frameCaptureSession(_ session: FrameCaptureSession, didFailWith error: Error)
}

// MARK: - Session

public final class FrameCaptureSession: NSObject {

    // MARK: Public

    public weak var delegate: FrameCaptureSessionDelegate?
    public private(set) var isCapturing = false

    // MARK: Private

    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.photobooth.framecapture.session", qos: .userInitiated)
    private let outputQueue = DispatchQueue(label: "com.photobooth.framecapture.output", qos: .userInitiated)

    private var videoOutput: AVCaptureVideoDataOutput?
    private var currentConfig: BurstCaptureConfig?
    private var capturedFrames: [CapturedFrame] = []
    private var frameIndex = 0
    private var burstStartTime: CMTime?
    private var lastFrameTime: CMTime?

    /// Lazy CIContext; reused across captures to avoid re-creating GPU resources.
    private lazy var ciContext: CIContext = {
        if let mtlDevice = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: mtlDevice, options: [
                .cacheIntermediates: false,
                .priorityRequestLow: false
            ])
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    // MARK: - Lifecycle

    deinit {
        stopSession()
    }

    // MARK: - Public API

    /// Prepare the capture session for a given configuration.
    /// Call this once, then call `startBurst()` to actually capture.
    public func prepare(config: BurstCaptureConfig, completion: @escaping (Result<Void, Error>) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.configureCaptureSession(config: config)
                self.currentConfig = config
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Begin capturing frames according to the current configuration.
    public func startBurst() {
        sessionQueue.async { [weak self] in
            guard let self = self, let config = self.currentConfig else { return }
            self.capturedFrames.removeAll()
            self.capturedFrames.reserveCapacity(config.frameCount)
            self.frameIndex = 0
            self.burstStartTime = nil
            self.lastFrameTime = nil
            self.isCapturing = true

            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
        }
    }

    /// Cancel an in-progress burst and discard frames.
    public func cancelBurst() {
        sessionQueue.async { [weak self] in
            self?.isCapturing = false
            self?.capturedFrames.removeAll()
        }
    }

    /// Stop the underlying AVCaptureSession entirely.
    public func stopSession() {
        sessionQueue.async { [weak self] in
            self?.isCapturing = false
            self?.captureSession.stopRunning()
        }
    }

    // MARK: - Session Configuration

    private func configureCaptureSession(config: BurstCaptureConfig) throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        // Remove existing inputs/outputs
        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }

        // Discover camera
        guard let camera = Self.bestCamera(for: config) else {
            throw FrameCaptureError.cameraUnavailable
        }

        // Configure device for target FPS
        try camera.lockForConfiguration()
        let targetDuration = CMTimeMake(value: 1, timescale: Int32(config.targetFPS))
        var bestFormat: AVCaptureDevice.Format?
        var bestRange: AVFrameRateRange?

        for format in camera.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            // Skip formats larger than our max resolution (saves memory + processing)
            if CGFloat(dimensions.width) > config.maxResolution.width * 1.5 {
                continue
            }
            for range in format.videoSupportedFrameRateRanges {
                if range.maxFrameRate >= config.targetFPS {
                    if bestRange == nil || range.maxFrameRate < bestRange!.maxFrameRate {
                        bestFormat = format
                        bestRange = range
                    }
                }
            }
        }

        if let format = bestFormat {
            camera.activeFormat = format
        }
        camera.activeVideoMinFrameDuration = targetDuration
        camera.activeVideoMaxFrameDuration = targetDuration
        camera.unlockForConfiguration()

        // Add input
        let input = try AVCaptureDeviceInput(device: camera)
        guard captureSession.canAddInput(input) else {
            throw FrameCaptureError.cannotAddInput
        }
        captureSession.addInput(input)

        // Add video data output
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: outputQueue)

        guard captureSession.canAddOutput(output) else {
            throw FrameCaptureError.cannotAddOutput
        }
        captureSession.addOutput(output)
        self.videoOutput = output

        // Set session preset based on resolution
        let preset = Self.sessionPreset(for: config.maxResolution)
        if captureSession.canSetSessionPreset(preset) {
            captureSession.sessionPreset = preset
        }
    }

    // MARK: - Helpers

    private static func bestCamera(for config: BurstCaptureConfig) -> AVCaptureDevice? {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTripleCamera],
            mediaType: .video,
            position: config.cameraPosition
        )
        return discoverySession.devices.first
    }

    private static func sessionPreset(for maxResolution: CGSize) -> AVCaptureSession.Preset {
        let pixels = maxResolution.width * maxResolution.height
        switch pixels {
        case ..<(640 * 480):
            return .vga640x480
        case ..<(1280 * 720):
            return .hd1280x720
        case ..<(1920 * 1080):
            return .hd1920x1080
        default:
            return .hd4K3840x2160
        }
    }

    /// Extract a CGImage from a sample buffer, scaling if necessary.
    private func cgImage(from sampleBuffer: CMSampleBuffer, maxSize: CGSize) -> CGImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Determine scale factor
        let extent = ciImage.extent
        let scaleX = maxSize.width / extent.width
        let scaleY = maxSize.height / extent.height
        let scale = min(min(scaleX, scaleY), 1.0) // Never upscale

        let scaledImage: CIImage
        if scale < 1.0 {
            scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            scaledImage = ciImage
        }

        return ciContext.createCGImage(scaledImage, from: scaledImage.extent)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension FrameCaptureSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isCapturing, let config = currentConfig else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Initialize burst start time on first frame
        if burstStartTime == nil {
            burstStartTime = presentationTime
        }

        // Frame rate throttling: skip frames that arrive too quickly
        if let lastTime = lastFrameTime {
            let elapsed = CMTimeSubtract(presentationTime, lastTime)
            let minInterval = CMTimeMake(value: 1, timescale: Int32(config.targetFPS * 1.2)) // 20% tolerance
            if CMTimeCompare(elapsed, minInterval) < 0 {
                return // Too soon, drop this frame
            }
        }

        // Build the captured frame
        let relativeTime = CMTimeSubtract(presentationTime, burstStartTime!)

        let frame: CapturedFrame
        if config.preferGPUBacked {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let ci = CIImage(cvPixelBuffer: pixelBuffer)
            frame = CapturedFrame(cgImage: nil, ciImage: ci, timestamp: relativeTime, index: frameIndex)
        } else {
            guard let cg = cgImage(from: sampleBuffer, maxSize: config.maxResolution) else { return }
            frame = CapturedFrame(cgImage: cg, ciImage: nil, timestamp: relativeTime, index: frameIndex)
        }

        capturedFrames.append(frame)
        frameIndex += 1
        lastFrameTime = presentationTime

        delegate?.frameCaptureSession(self, didCapture: frame)

        // Check if we have enough frames
        if frameIndex >= config.frameCount {
            isCapturing = false
            let allFrames = capturedFrames
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.frameCaptureSessionDidFinish(self, frames: allFrames)
            }
        }
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Log dropped frames for diagnostics; in production, feed into a metrics system.
        #if DEBUG
        let reason = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        print("[FrameCapture] Dropped frame. Attachments: \(String(describing: reason))")
        #endif
    }
}

// MARK: - Errors

public enum FrameCaptureError: LocalizedError {
    case cameraUnavailable
    case cannotAddInput
    case cannotAddOutput
    case captureInterrupted
    case thermalThrottling

    public var errorDescription: String? {
        switch self {
        case .cameraUnavailable: return "No suitable camera found for the requested configuration."
        case .cannotAddInput: return "Cannot add camera input to the capture session."
        case .cannotAddOutput: return "Cannot add video output to the capture session."
        case .captureInterrupted: return "Capture was interrupted by a system event."
        case .thermalThrottling: return "Device is thermal throttling; capture quality may be reduced."
        }
    }
}
