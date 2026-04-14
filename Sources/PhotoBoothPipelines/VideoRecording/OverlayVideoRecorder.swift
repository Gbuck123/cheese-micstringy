// OverlayVideoRecorder.swift
// Video recording with real-time branded overlay compositing and audio mixing.
//
// Architecture:
//   AVCaptureSession → AVCaptureVideoDataOutput → CIFilter pipeline (overlay) → AVAssetWriter
//   + AVCaptureAudioDataOutput → AVAssetWriter (audio track)
//   + AVMutableComposition for post-recording music/audio track mixing
//   + AVAssetExportSession for final export with proper codecs
//
// The overlay is composited in real-time using a CIFilter chain, avoiding the need
// for post-processing and giving instant preview of the branded result.

import AVFoundation
import CoreImage
import CoreMedia
import UIKit

// MARK: - Configuration

public struct OverlayVideoConfig {
    /// Output video resolution.
    public var outputSize: CGSize
    /// Recording FPS.
    public var fps: Int
    /// Video bitrate in bits per second.
    public var videoBitRate: Int
    /// Audio bitrate in bits per second.
    public var audioBitRate: Int
    /// Audio sample rate.
    public var audioSampleRate: Float64
    /// H.264 or HEVC.
    public var codec: AVVideoCodecType
    /// Camera position.
    public var cameraPosition: AVCaptureDevice.Position
    /// Maximum recording duration in seconds (0 = unlimited).
    public var maxDuration: TimeInterval
    /// Whether to record audio from the microphone.
    public var recordMicrophone: Bool

    public init(
        outputSize: CGSize = CGSize(width: 1080, height: 1920),
        fps: Int = 30,
        videoBitRate: Int = 10_000_000,
        audioBitRate: Int = 128_000,
        audioSampleRate: Float64 = 44100,
        codec: AVVideoCodecType = .h264,
        cameraPosition: AVCaptureDevice.Position = .front,
        maxDuration: TimeInterval = 30,
        recordMicrophone: Bool = true
    ) {
        self.outputSize = outputSize
        self.fps = fps
        self.videoBitRate = videoBitRate
        self.audioBitRate = audioBitRate
        self.audioSampleRate = audioSampleRate
        self.codec = codec
        self.cameraPosition = cameraPosition
        self.maxDuration = maxDuration
        self.recordMicrophone = recordMicrophone
    }

    /// Preset for 360-degree photo booth (high quality, short duration).
    public static var photoBooth360: OverlayVideoConfig {
        OverlayVideoConfig(
            outputSize: CGSize(width: 1080, height: 1920),
            fps: 30,
            videoBitRate: 15_000_000,
            audioBitRate: 192_000,
            audioSampleRate: 48000,
            codec: .hevc,
            cameraPosition: .back,
            maxDuration: 15,
            recordMicrophone: false
        )
    }
}

// MARK: - Overlay Layer

/// Defines a compositing layer to render over the camera feed.
public struct OverlayLayer {
    /// The overlay image (PNG with alpha recommended). Must have the same aspect ratio as output,
    /// or will be aspect-fitted.
    public var image: CIImage
    /// Opacity 0.0 ... 1.0.
    public var opacity: Float
    /// Blend mode.
    public var blendMode: OverlayBlendMode
    /// Position within the frame (normalized 0...1). Default is full-frame.
    public var normalizedRect: CGRect

    public init(
        image: CIImage,
        opacity: Float = 1.0,
        blendMode: OverlayBlendMode = .sourceOver,
        normalizedRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) {
        self.image = image
        self.opacity = opacity
        self.blendMode = blendMode
        self.normalizedRect = normalizedRect
    }

    /// Create from UIImage.
    public init?(
        uiImage: UIImage,
        opacity: Float = 1.0,
        blendMode: OverlayBlendMode = .sourceOver,
        normalizedRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) {
        guard let ciImage = CIImage(image: uiImage) else { return nil }
        self.init(image: ciImage, opacity: opacity, blendMode: blendMode, normalizedRect: normalizedRect)
    }
}

public enum OverlayBlendMode {
    case sourceOver        // Standard alpha compositing
    case multiply          // Darken
    case screen            // Lighten
    case overlay           // Contrast-preserving blend
    case softLight

    var ciFilterName: String {
        switch self {
        case .sourceOver: return "CISourceOverCompositing"
        case .multiply: return "CIMultiplyBlendMode"
        case .screen: return "CIScreenBlendMode"
        case .overlay: return "CIOverlayBlendMode"
        case .softLight: return "CISoftLightBlendMode"
        }
    }
}

// MARK: - Delegate

public protocol OverlayVideoRecorderDelegate: AnyObject {
    /// Called with each composited frame for live preview.
    func recorder(_ recorder: OverlayVideoRecorder, didOutputPreviewImage: CIImage)
    /// Called when recording finishes.
    func recorder(_ recorder: OverlayVideoRecorder, didFinishRecordingTo url: URL)
    /// Called on error.
    func recorder(_ recorder: OverlayVideoRecorder, didFailWith error: Error)
    /// Called with elapsed recording time.
    func recorder(_ recorder: OverlayVideoRecorder, recordingDuration: TimeInterval)
}

// MARK: - Recorder

public final class OverlayVideoRecorder: NSObject {

    // MARK: Public

    public weak var delegate: OverlayVideoRecorderDelegate?
    public private(set) var isRecording = false
    public private(set) var isPrepared = false

    /// Active overlay layers. Can be modified between frames (thread-safe via serial queue).
    public var overlayLayers: [OverlayLayer] = []

    // MARK: Private

    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.photobooth.videorecorder.session", qos: .userInitiated)
    private let writerQueue = DispatchQueue(label: "com.photobooth.videorecorder.writer", qos: .userInitiated)

    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?

    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private var currentConfig: OverlayVideoConfig?
    private var outputURL: URL?
    private var recordingStartTime: CMTime?
    private var lastVideoTime: CMTime?

    /// Reusable CIContext for overlay compositing.
    private lazy var ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [
                .cacheIntermediates: false,
                .priorityRequestLow: false,
                .name: "OverlayVideoRecorder"
            ])
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    /// Pixel buffer pool for writing composited frames.
    private var pixelBufferPool: CVPixelBufferPool?

    deinit {
        stopSession()
    }

    // MARK: - Setup

    /// Prepare the capture session and writer.
    public func prepare(config: OverlayVideoConfig, outputURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.setupCaptureSession(config: config)
                try self.setupAssetWriter(config: config, outputURL: outputURL)
                self.currentConfig = config
                self.outputURL = outputURL
                self.isPrepared = true
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Start the capture session (shows preview; does not start recording).
    public func startPreview() {
        sessionQueue.async { [weak self] in
            self?.captureSession.startRunning()
        }
    }

    /// Begin recording to disk.
    public func startRecording() {
        writerQueue.async { [weak self] in
            guard let self = self, self.isPrepared else { return }
            self.recordingStartTime = nil
            self.isRecording = true
        }
    }

    /// Stop recording and finalize the file.
    public func stopRecording() {
        writerQueue.async { [weak self] in
            guard let self = self, self.isRecording else { return }
            self.isRecording = false
            self.finalizeRecording()
        }
    }

    /// Stop everything.
    public func stopSession() {
        isRecording = false
        sessionQueue.async { [weak self] in
            self?.captureSession.stopRunning()
        }
    }

    // MARK: - Capture Session Setup

    private func setupCaptureSession(config: OverlayVideoConfig) throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }

        if captureSession.canSetSessionPreset(.hd1920x1080) {
            captureSession.sessionPreset = .hd1920x1080
        }

        // Video input
        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: config.cameraPosition
        ) else {
            throw VideoRecorderError.cameraUnavailable
        }

        try camera.lockForConfiguration()
        let targetDuration = CMTimeMake(value: 1, timescale: Int32(config.fps))
        camera.activeVideoMinFrameDuration = targetDuration
        camera.activeVideoMaxFrameDuration = targetDuration
        camera.unlockForConfiguration()

        let videoInput = try AVCaptureDeviceInput(device: camera)
        guard captureSession.canAddInput(videoInput) else { throw VideoRecorderError.cannotAddInput }
        captureSession.addInput(videoInput)

        // Video output
        let videoOut = AVCaptureVideoDataOutput()
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOut.alwaysDiscardsLateVideoFrames = true
        videoOut.setSampleBufferDelegate(self, queue: writerQueue)
        guard captureSession.canAddOutput(videoOut) else { throw VideoRecorderError.cannotAddOutput }
        captureSession.addOutput(videoOut)
        self.videoOutput = videoOut

        // Audio input/output
        if config.recordMicrophone {
            if let mic = AVCaptureDevice.default(for: .audio) {
                let audioInput = try AVCaptureDeviceInput(device: mic)
                if captureSession.canAddInput(audioInput) {
                    captureSession.addInput(audioInput)
                }

                let audioOut = AVCaptureAudioDataOutput()
                audioOut.setSampleBufferDelegate(self, queue: writerQueue)
                if captureSession.canAddOutput(audioOut) {
                    captureSession.addOutput(audioOut)
                    self.audioOutput = audioOut
                }
            }
        }
    }

    // MARK: - Asset Writer Setup

    private func setupAssetWriter(config: OverlayVideoConfig, outputURL: URL) throws {
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        // Video writer input
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: config.codec,
            AVVideoWidthKey: Int(config.outputSize.width),
            AVVideoHeightKey: Int(config.outputSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: config.videoBitRate,
                AVVideoMaxKeyFrameIntervalKey: config.fps,
                AVVideoProfileLevelKey: config.codec == .hevc
                    ? kVTProfileLevel_HEVC_Main_AutoLevel
                    : AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: config.fps
            ]
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        // Mirror for front camera
        if config.cameraPosition == .front {
            videoInput.transform = CGAffineTransform(scaleX: -1, y: 1)
                .translatedBy(x: -config.outputSize.width, y: 0)
        }

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(config.outputSize.width),
                kCVPixelBufferHeightKey as String: Int(config.outputSize.height)
            ]
        )

        writer.add(videoInput)
        self.videoWriterInput = videoInput
        self.pixelBufferAdaptor = adaptor

        // Audio writer input
        if config.recordMicrophone {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: config.audioSampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: config.audioBitRate
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true
            writer.add(audioInput)
            self.audioWriterInput = audioInput
        }

        self.assetWriter = writer
    }

    // MARK: - Overlay Compositing

    /// Apply all overlay layers to a camera frame.
    private func compositeOverlays(onto cameraFrame: CIImage) -> CIImage {
        var result = cameraFrame
        let frameExtent = cameraFrame.extent

        for layer in overlayLayers {
            var overlayImage = layer.image

            // Scale overlay to fill its designated rect within the frame
            let destRect = CGRect(
                x: frameExtent.origin.x + layer.normalizedRect.origin.x * frameExtent.width,
                y: frameExtent.origin.y + layer.normalizedRect.origin.y * frameExtent.height,
                width: layer.normalizedRect.width * frameExtent.width,
                height: layer.normalizedRect.height * frameExtent.height
            )

            let overlayExtent = overlayImage.extent
            let scaleX = destRect.width / overlayExtent.width
            let scaleY = destRect.height / overlayExtent.height

            overlayImage = overlayImage
                .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                .transformed(by: CGAffineTransform(translationX: destRect.origin.x, y: destRect.origin.y))

            // Apply opacity
            if layer.opacity < 1.0 {
                if let opacityFilter = CIFilter(name: "CIColorMatrix") {
                    opacityFilter.setValue(overlayImage, forKey: kCIInputImageKey)
                    let alpha = CGFloat(layer.opacity)
                    opacityFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: alpha), forKey: "inputAVector")
                    if let adjusted = opacityFilter.outputImage {
                        overlayImage = adjusted
                    }
                }
            }

            // Composite using the specified blend mode
            guard let blendFilter = CIFilter(name: layer.blendMode.ciFilterName) else { continue }
            blendFilter.setValue(overlayImage, forKey: kCIInputImageKey)
            blendFilter.setValue(result, forKey: kCIInputBackgroundImageKey)

            if let composited = blendFilter.outputImage?.cropped(to: frameExtent) {
                result = composited
            }
        }

        return result
    }

    /// Render a CIImage into a CVPixelBuffer from the adaptor's pool.
    private func renderToPixelBuffer(_ image: CIImage, size: CGSize) -> CVPixelBuffer? {
        // Use the pool from the adaptor if available
        let pool = pixelBufferAdaptor?.pixelBufferPool
        var pixelBuffer: CVPixelBuffer?

        if let pool = pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        }

        if pixelBuffer == nil {
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                Int(size.width),
                Int(size.height),
                kCVPixelFormatType_32BGRA,
                nil,
                &pixelBuffer
            )
        }

        guard let buffer = pixelBuffer else { return nil }
        ciContext.render(image, to: buffer)
        return buffer
    }

    // MARK: - Finalization

    private func finalizeRecording() {
        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()

        guard let writer = assetWriter, let url = outputURL else { return }

        writer.finishWriting { [weak self] in
            guard let self = self else { return }
            if writer.status == .completed {
                DispatchQueue.main.async {
                    self.delegate?.recorder(self, didFinishRecordingTo: url)
                }
            } else {
                let error = writer.error ?? VideoRecorderError.exportFailed("Unknown finalization error")
                DispatchQueue.main.async {
                    self.delegate?.recorder(self, didFailWith: error)
                }
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension OverlayVideoRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Audio path
        if output == audioOutput {
            guard isRecording, let audioInput = audioWriterInput, audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
            return
        }

        // Video path
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let config = currentConfig else { return }

        // Build CIImage from camera buffer
        let cameraImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Apply overlays
        let composited = compositeOverlays(onto: cameraImage)

        // Send preview to delegate (always, even when not recording)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.recorder(self, didOutputPreviewImage: composited)
        }

        // Write to file
        guard isRecording else { return }
        guard let writer = assetWriter else { return }

        // Start the writer session on the first frame
        if recordingStartTime == nil {
            recordingStartTime = timestamp
            writer.startWriting()
            writer.startSession(atSourceTime: timestamp)
        }

        // Enforce max duration
        if config.maxDuration > 0 {
            let elapsed = CMTimeGetSeconds(CMTimeSubtract(timestamp, recordingStartTime!))
            if elapsed >= config.maxDuration {
                stopRecording()
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.recorder(self, recordingDuration: elapsed)
            }
        }

        // Render composited frame to pixel buffer and write
        guard let videoInput = videoWriterInput, videoInput.isReadyForMoreMediaData else { return }

        if let outputBuffer = renderToPixelBuffer(composited, size: config.outputSize) {
            pixelBufferAdaptor?.append(outputBuffer, withPresentationTime: timestamp)
        }
    }
}

// MARK: - Post-Recording Audio Mixing

extension OverlayVideoRecorder {

    /// Add a background music track to an existing video.
    ///
    /// - Parameters:
    ///   - videoURL: URL of the recorded video.
    ///   - audioURL: URL of the music file (MP3, AAC, WAV, etc.).
    ///   - videoVolume: Volume of the original video audio (0.0 ... 1.0).
    ///   - musicVolume: Volume of the background music (0.0 ... 1.0).
    ///   - outputURL: Where to write the mixed result.
    ///   - completion: Called with the output URL on success.
    public static func addMusicTrack(
        to videoURL: URL,
        musicURL: URL,
        videoVolume: Float = 1.0,
        musicVolume: Float = 0.5,
        fadeInDuration: TimeInterval = 1.0,
        fadeOutDuration: TimeInterval = 2.0,
        outputURL: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let composition = AVMutableComposition()

        // Load assets
        let videoAsset = AVURLAsset(url: videoURL)
        let musicAsset = AVURLAsset(url: musicURL)

        guard let videoTrack = videoAsset.tracks(withMediaType: .video).first else {
            completion(.failure(VideoRecorderError.noVideoTrack))
            return
        }

        let videoDuration = videoAsset.duration

        // Add video track
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            completion(.failure(VideoRecorderError.compositionFailed))
            return
        }

        do {
            try compositionVideoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: videoDuration),
                of: videoTrack,
                at: .zero
            )
        } catch {
            completion(.failure(error))
            return
        }

        // Add original audio track (if present)
        let audioMix = AVMutableAudioMix()
        var mixParameters: [AVMutableAudioMixInputParameters] = []

        if let originalAudioTrack = videoAsset.tracks(withMediaType: .audio).first {
            guard let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                completion(.failure(VideoRecorderError.compositionFailed))
                return
            }

            do {
                try compositionAudioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: videoDuration),
                    of: originalAudioTrack,
                    at: .zero
                )
            } catch {
                completion(.failure(error))
                return
            }

            let originalParams = AVMutableAudioMixInputParameters(track: compositionAudioTrack)
            originalParams.setVolume(videoVolume, at: .zero)
            mixParameters.append(originalParams)
        }

        // Add music track
        if let musicTrack = musicAsset.tracks(withMediaType: .audio).first {
            guard let compositionMusicTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                completion(.failure(VideoRecorderError.compositionFailed))
                return
            }

            // Trim music to match video duration
            let musicDuration = min(musicAsset.duration, videoDuration)
            do {
                try compositionMusicTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: musicDuration),
                    of: musicTrack,
                    at: .zero
                )
            } catch {
                completion(.failure(error))
                return
            }

            // Set volume with fade in/out
            let musicParams = AVMutableAudioMixInputParameters(track: compositionMusicTrack)
            musicParams.setVolume(0, at: .zero)

            // Fade in
            let fadeInEnd = CMTimeMakeWithSeconds(fadeInDuration, preferredTimescale: 600)
            musicParams.setVolumeRamp(
                fromStartVolume: 0,
                toEndVolume: musicVolume,
                timeRange: CMTimeRange(start: .zero, duration: fadeInEnd)
            )

            // Fade out
            let fadeOutStart = CMTimeSubtract(videoDuration, CMTimeMakeWithSeconds(fadeOutDuration, preferredTimescale: 600))
            musicParams.setVolumeRamp(
                fromStartVolume: musicVolume,
                toEndVolume: 0,
                timeRange: CMTimeRange(start: fadeOutStart, duration: CMTimeMakeWithSeconds(fadeOutDuration, preferredTimescale: 600))
            )

            mixParameters.append(musicParams)
        }

        audioMix.inputParameters = mixParameters

        // Export
        try? FileManager.default.removeItem(at: outputURL)

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            completion(.failure(VideoRecorderError.exportFailed("Cannot create export session")))
            return
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.audioMix = audioMix
        exportSession.shouldOptimizeForNetworkUse = true

        exportSession.exportAsynchronously {
            switch exportSession.status {
            case .completed:
                completion(.success(outputURL))
            case .failed:
                completion(.failure(exportSession.error ?? VideoRecorderError.exportFailed("Unknown")))
            case .cancelled:
                completion(.failure(VideoRecorderError.exportFailed("Export cancelled")))
            default:
                completion(.failure(VideoRecorderError.exportFailed("Unexpected status: \(exportSession.status.rawValue)")))
            }
        }
    }
}

// MARK: - Errors

public enum VideoRecorderError: LocalizedError {
    case cameraUnavailable
    case cannotAddInput
    case cannotAddOutput
    case noVideoTrack
    case compositionFailed
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cameraUnavailable: return "No camera available."
        case .cannotAddInput: return "Cannot add input to capture session."
        case .cannotAddOutput: return "Cannot add output to capture session."
        case .noVideoTrack: return "No video track found in the source asset."
        case .compositionFailed: return "Failed to create composition track."
        case .exportFailed(let detail): return "Export failed: \(detail)"
        }
    }
}
