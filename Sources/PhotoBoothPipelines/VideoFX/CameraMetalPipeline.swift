// CameraMetalPipeline.swift
// Full pipeline: AVCaptureVideoDataOutput → Metal filter chain → MTKView display.
// Triple-buffered with semaphore gating to maintain 30/60fps.

import Foundation
import AVFoundation
import Metal
import MetalKit
import CoreVideo

/// Manages the complete camera → Metal processing → display pipeline.
/// Owns the AVCaptureSession configuration and the filter chain.
///
/// Usage:
/// ```swift
/// let pipeline = CameraMetalPipeline()
/// pipeline.filterChain.append(VintageFilter())
/// pipeline.filterChain.append(VignetteFilter())
/// pipeline.attachPreview(to: mtkView)
/// pipeline.start()
/// ```
public final class CameraMetalPipeline: NSObject {

    // MARK: - Public Properties

    /// The filter chain. Add/remove filters before or during capture.
    public let filterChain: FilterChain

    /// Target frame rate for the camera. 30 is reliable on all iPads; 60 is available on Pro models.
    public var targetFrameRate: Int = 30

    /// Preferred camera position.
    public var cameraPosition: AVCaptureDevice.Position = .front

    /// Current frames per second (measured).
    public private(set) var measuredFPS: Double = 0

    // MARK: - Private Properties

    private let context: MetalContext
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "com.photobooth.capture", qos: .userInteractive)

    /// Triple-buffering semaphore: allows up to 3 frames in flight.
    /// This prevents the CPU from getting too far ahead of the GPU.
    private let inflightSemaphore = DispatchSemaphore(value: 3)

    /// The MTKView we render into.
    private weak var mtkView: MTKView?

    /// Render pipeline state for drawing a full-screen textured quad (for MTKView).
    private var renderPipelineState: MTLRenderPipelineState?

    /// FPS measurement.
    private var frameCount: Int = 0
    private var fpsTimestamp: CFAbsoluteTime = 0

    /// The most recently processed texture, ready for display.
    private var displayTexture: MTLTexture?
    private let displayTextureLock = NSLock()

    // MARK: - Init

    public init(context: MetalContext = .shared) {
        self.context = context
        self.filterChain = FilterChain(context: context)
        super.init()
    }

    deinit {
        stop()
    }

    // MARK: - Preview Attachment

    /// Attach the pipeline's output to an MTKView for live display.
    /// The MTKView should be configured for `.bgra8Unorm` pixel format.
    public func attachPreview(to view: MTKView) {
        view.device = context.device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.isPaused = true           // We drive draws manually from the capture callback.
        view.enableSetNeedsDisplay = false
        view.delegate = self
        self.mtkView = view
    }

    // MARK: - Session Lifecycle

    public func start() {
        captureQueue.async { [weak self] in
            self?.configureCaptureSession()
            self?.captureSession.startRunning()
        }
    }

    public func stop() {
        captureSession.stopRunning()
    }

    // MARK: - Capture Session Configuration

    private func configureCaptureSession() {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.sessionPreset = .hd1920x1080

        // Camera input
        guard let camera = bestCamera(for: cameraPosition),
              let input = try? AVCaptureDeviceInput(device: camera) else {
            print("[CameraMetalPipeline] No suitable camera found.")
            return
        }

        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        // Configure frame rate
        configureFrameRate(for: camera)

        // Video data output
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        // Fix orientation — for a photo booth, we typically want landscape.
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if connection.isVideoMirroringSupported && cameraPosition == .front {
                connection.isVideoMirrored = true
            }
        }
    }

    private func bestCamera(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        // Prefer the wide-angle camera on iPad.
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        return discoverySession.devices.first
    }

    private func configureFrameRate(for device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            let targetDuration = CMTime(value: 1, timescale: CMTimeScale(targetFrameRate))
            device.activeVideoMinFrameDuration = targetDuration
            device.activeVideoMaxFrameDuration = targetDuration
            device.unlockForConfiguration()
        } catch {
            print("[CameraMetalPipeline] Could not lock device for frame rate configuration: \(error)")
        }
    }

    // MARK: - FPS Measurement

    private func updateFPS() {
        frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - fpsTimestamp
        if elapsed >= 1.0 {
            measuredFPS = Double(frameCount) / elapsed
            frameCount = 0
            fpsTimestamp = now
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraMetalPipeline: AVCaptureVideoDataOutputSampleBufferDelegate {

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Gate on the inflight semaphore to prevent CPU from outrunning GPU.
        guard inflightSemaphore.wait(timeout: .now() + .milliseconds(32)) == .success else {
            return // Drop frame if GPU is backed up.
        }

        // Convert CVPixelBuffer → MTLTexture (zero-copy on Apple Silicon).
        guard let inputTexture = context.texture(from: pixelBuffer) else {
            inflightSemaphore.signal()
            return
        }

        // Create command buffer.
        let commandBuffer = context.makeCommandBuffer(label: "CameraFrame")

        // Run the filter chain.
        let outputTexture = filterChain.encode(commandBuffer: commandBuffer, sourceTexture: inputTexture)

        // On completion: signal semaphore, update display texture, trigger MTKView draw.
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inflightSemaphore.signal()
        }

        // Store the output texture for the MTKView delegate to read.
        displayTextureLock.lock()
        displayTexture = outputTexture
        displayTextureLock.unlock()

        commandBuffer.commit()

        // Trigger a draw on the MTKView (on main thread).
        DispatchQueue.main.async { [weak self] in
            self?.mtkView?.draw()
        }

        updateFPS()
    }

    public func captureOutput(_ output: AVCaptureOutput,
                              didDrop sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        // Optional: track dropped frames for adaptive quality.
        print("[CameraMetalPipeline] Frame dropped.")
    }
}

// MARK: - MTKViewDelegate

extension CameraMetalPipeline: MTKViewDelegate {

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // No-op; we handle resolution from the camera frame size.
    }

    public func draw(in view: MTKView) {
        displayTextureLock.lock()
        guard let texture = displayTexture else {
            displayTextureLock.unlock()
            return
        }
        displayTextureLock.unlock()

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor else { return }

        let commandBuffer = context.makeCommandBuffer(label: "Display")

        // Blit the processed texture to the drawable.
        // Using a blit encoder is simpler than a render pass for full-screen copy.
        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            let srcSize = MTLSize(width: min(texture.width, drawable.texture.width),
                                  height: min(texture.height, drawable.texture.height),
                                  depth: 1)
            blitEncoder.copy(
                from: texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: srcSize,
                to: drawable.texture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blitEncoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
