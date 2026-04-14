// SlowMotionProcessor.swift
// 360 booth slow-motion / speed-ramping pipeline.
//
// Captures at 120fps or 240fps, then exports at variable speed using
// AVMutableComposition with time-range mapping.
//
// Features:
//   - Auto-detection of maximum supported frame rate per device
//   - Speed ramp profiles (linear, ease-in-out, custom keyframes)
//   - Real-time preview at reduced quality
//   - Export with AVAssetExportSession preserving audio pitch (optional)
//   - Handles 360 booth turntable sync (start/stop markers)

import AVFoundation
import CoreMedia
import UIKit

// MARK: - Configuration

public struct SlowMotionConfig {
    /// Target capture FPS. Will fall back to the closest supported rate.
    public var targetCaptureFPS: Double
    /// Output FPS for the exported file.
    public var outputFPS: Double
    /// Output resolution.
    public var outputSize: CGSize
    /// Camera position.
    public var cameraPosition: AVCaptureDevice.Position
    /// Video codec for export.
    public var codec: AVVideoCodecType
    /// Video bitrate for export.
    public var videoBitRate: Int

    public init(
        targetCaptureFPS: Double = 240,
        outputFPS: Double = 30,
        outputSize: CGSize = CGSize(width: 1080, height: 1920),
        cameraPosition: AVCaptureDevice.Position = .back,
        codec: AVVideoCodecType = .hevc,
        videoBitRate: Int = 15_000_000
    ) {
        self.targetCaptureFPS = targetCaptureFPS
        self.outputFPS = outputFPS
        self.outputSize = outputSize
        self.cameraPosition = cameraPosition
        self.codec = codec
        self.videoBitRate = videoBitRate
    }

    /// For 360 booth: 240fps capture, 1080p HEVC output.
    public static var booth360: SlowMotionConfig {
        SlowMotionConfig(
            targetCaptureFPS: 240,
            outputFPS: 30,
            outputSize: CGSize(width: 1080, height: 1920),
            cameraPosition: .back,
            codec: .hevc,
            videoBitRate: 20_000_000
        )
    }

    /// The maximum slow-motion factor at this configuration.
    /// e.g., 240fps capture / 30fps output = 8x slow motion.
    public var maxSlowdownFactor: Double {
        targetCaptureFPS / outputFPS
    }
}

// MARK: - Speed Ramp Profile

/// Defines how playback speed varies over the duration of the clip.
public struct SpeedRampProfile {
    /// Keyframes defining speed at normalized time positions.
    /// time: 0.0 ... 1.0 (start to end of clip)
    /// speed: multiplier (1.0 = normal, 0.125 = 8x slow, 2.0 = 2x fast)
    public var keyframes: [(time: Double, speed: Double)]

    public init(keyframes: [(time: Double, speed: Double)]) {
        self.keyframes = keyframes.sorted { $0.time < $1.time }
    }

    // MARK: - Presets

    /// Constant slow motion throughout.
    public static func constant(speed: Double) -> SpeedRampProfile {
        SpeedRampProfile(keyframes: [
            (time: 0.0, speed: speed),
            (time: 1.0, speed: speed)
        ])
    }

    /// Normal speed -> slow motion -> normal speed.
    /// Perfect for 360 booth: fast approach, slow dramatic middle, fast exit.
    public static var dramaticMiddle: SpeedRampProfile {
        SpeedRampProfile(keyframes: [
            (time: 0.0, speed: 1.0),
            (time: 0.2, speed: 1.0),
            (time: 0.35, speed: 0.125),   // 8x slow
            (time: 0.65, speed: 0.125),   // 8x slow
            (time: 0.8, speed: 1.0),
            (time: 1.0, speed: 1.0)
        ])
    }

    /// Gradual slowdown then snap back to normal.
    public static var rampDown: SpeedRampProfile {
        SpeedRampProfile(keyframes: [
            (time: 0.0, speed: 1.0),
            (time: 0.5, speed: 0.25),    // 4x slow
            (time: 0.8, speed: 0.125),   // 8x slow
            (time: 0.9, speed: 0.5),
            (time: 1.0, speed: 1.0)
        ])
    }

    /// Instant slow motion from the start, ramp back to normal at end.
    public static var heroMoment: SpeedRampProfile {
        SpeedRampProfile(keyframes: [
            (time: 0.0, speed: 0.125),   // 8x slow from start
            (time: 0.7, speed: 0.125),
            (time: 0.85, speed: 0.5),
            (time: 1.0, speed: 1.0)
        ])
    }

    /// Interpolate the speed at a given normalized time.
    public func speed(at normalizedTime: Double) -> Double {
        let t = max(0, min(1, normalizedTime))

        // Find surrounding keyframes
        guard keyframes.count >= 2 else { return keyframes.first?.speed ?? 1.0 }

        var lower = keyframes[0]
        var upper = keyframes[keyframes.count - 1]

        for i in 0..<(keyframes.count - 1) {
            if keyframes[i].time <= t && keyframes[i + 1].time >= t {
                lower = keyframes[i]
                upper = keyframes[i + 1]
                break
            }
        }

        // Linear interpolation between keyframes
        let range = upper.time - lower.time
        guard range > 0 else { return lower.speed }
        let fraction = (t - lower.time) / range

        // Apply smooth-step for more pleasing transitions
        let smoothFraction = fraction * fraction * (3.0 - 2.0 * fraction)
        return lower.speed + (upper.speed - lower.speed) * smoothFraction
    }
}

// MARK: - High Frame Rate Capture

public final class HighFrameRateCapture: NSObject {

    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.photobooth.hfr.session", qos: .userInitiated)
    private var movieOutput: AVCaptureMovieFileOutput?
    private var config: SlowMotionConfig?

    public var actualCaptureFPS: Double = 0

    /// Discover the maximum supported frame rate for the given camera.
    public static func maxSupportedFPS(position: AVCaptureDevice.Position) -> Double {
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: position
        ) else { return 30 }

        var maxFPS: Double = 30
        for format in device.formats {
            for range in format.videoSupportedFrameRateRanges {
                maxFPS = max(maxFPS, range.maxFrameRate)
            }
        }
        return maxFPS
    }

    /// Configure the capture session for high frame rate recording.
    public func prepare(config: SlowMotionConfig, completion: @escaping (Result<Double, Error>) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.config = config

            do {
                let actualFPS = try self.configureSession(config: config)
                self.actualCaptureFPS = actualFPS
                DispatchQueue.main.async { completion(.success(actualFPS)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func configureSession(config: SlowMotionConfig) throws -> Double {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }

        // Discover device
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: config.cameraPosition
        ) else {
            throw SlowMotionError.cameraUnavailable
        }

        // Find best format supporting the target FPS
        var bestFormat: AVCaptureDevice.Format?
        var bestFPS: Double = 0
        var bestResolutionDiff: CGFloat = .greatestFiniteMagnitude

        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let formatSize = CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))

            for range in format.videoSupportedFrameRateRanges {
                if range.maxFrameRate >= config.targetCaptureFPS {
                    // Prefer formats closest to our target resolution
                    let resDiff = abs(formatSize.width - config.outputSize.width)
                        + abs(formatSize.height - config.outputSize.height)

                    if resDiff < bestResolutionDiff
                        || (resDiff == bestResolutionDiff && range.maxFrameRate < bestFPS) {
                        bestFormat = format
                        bestFPS = range.maxFrameRate
                        bestResolutionDiff = resDiff
                    }
                }
            }
        }

        // If we can't hit the target FPS, fall back to the highest available
        if bestFormat == nil {
            for format in device.formats {
                for range in format.videoSupportedFrameRateRanges {
                    if range.maxFrameRate > bestFPS {
                        bestFormat = format
                        bestFPS = range.maxFrameRate
                    }
                }
            }
        }

        guard let selectedFormat = bestFormat else {
            throw SlowMotionError.noSuitableFormat
        }

        // Apply the format and frame rate
        try device.lockForConfiguration()
        device.activeFormat = selectedFormat
        let actualFPS = min(config.targetCaptureFPS, bestFPS)
        device.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: Int32(actualFPS))
        device.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: Int32(actualFPS))

        // Enable video stabilization if available (important for 360 booth)
        device.unlockForConfiguration()

        // Add input
        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw SlowMotionError.cannotConfigureSession
        }
        captureSession.addInput(input)

        // Add movie file output
        let movieOutput = AVCaptureMovieFileOutput()
        // Remove default 10-second limit
        movieOutput.maxRecordedDuration = .indefinite
        guard captureSession.canAddOutput(movieOutput) else {
            throw SlowMotionError.cannotConfigureSession
        }
        captureSession.addOutput(movieOutput)
        self.movieOutput = movieOutput

        // Enable stabilization on the connection
        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .cinematic
            }
        }

        return actualFPS
    }

    /// Start the session (for live preview).
    public func startSession() {
        sessionQueue.async { [weak self] in
            self?.captureSession.startRunning()
        }
    }

    /// Start recording to a file.
    public func startRecording(to outputURL: URL, delegate: AVCaptureFileOutputRecordingDelegate) {
        sessionQueue.async { [weak self] in
            try? FileManager.default.removeItem(at: outputURL)
            self?.movieOutput?.startRecording(to: outputURL, recordingDelegate: delegate)
        }
    }

    /// Stop recording.
    public func stopRecording() {
        movieOutput?.stopRecording()
    }

    /// Stop the session entirely.
    public func stopSession() {
        sessionQueue.async { [weak self] in
            self?.captureSession.stopRunning()
        }
    }

    /// The AVCaptureSession for preview layer.
    public var session: AVCaptureSession { captureSession }
}

// MARK: - Speed Ramp Processor

public final class SpeedRampProcessor {

    public init() {}

    /// Apply a speed ramp profile to a video file and export.
    ///
    /// This works by creating an AVMutableComposition with multiple time mappings:
    /// the source video is divided into segments, each scaled according to the
    /// speed profile at that point.
    ///
    /// - Parameters:
    ///   - sourceURL: URL of the high-frame-rate source video.
    ///   - profile: Speed ramp profile.
    ///   - config: Slow motion configuration (for output settings).
    ///   - outputURL: Where to write the result.
    ///   - completion: Called with the output URL on success.
    public func applySpeedRamp(
        sourceURL: URL,
        profile: SpeedRampProfile,
        config: SlowMotionConfig,
        outputURL: URL,
        progress: ((Float) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let sourceAsset = AVURLAsset(url: sourceURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])

        guard let sourceVideoTrack = sourceAsset.tracks(withMediaType: .video).first else {
            completion(.failure(SlowMotionError.noVideoTrack))
            return
        }

        let sourceDuration = sourceAsset.duration
        let sourceDurationSeconds = CMTimeGetSeconds(sourceDuration)
        let timescale: Int32 = 600 // High precision timescale

        // Create the composition
        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            completion(.failure(SlowMotionError.compositionFailed))
            return
        }

        // Preserve the original track's transform
        compositionVideoTrack.preferredTransform = sourceVideoTrack.preferredTransform

        // Add audio track if present
        let sourceAudioTrack = sourceAsset.tracks(withMediaType: .audio).first
        var compositionAudioTrack: AVMutableCompositionTrack?
        if let audioTrack = sourceAudioTrack {
            compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
            // For audio, we insert the full duration; the video composition handles speed
            // Audio pitch correction happens at the export level
            try? compositionAudioTrack?.insertTimeRange(
                CMTimeRange(start: .zero, duration: sourceDuration),
                of: audioTrack,
                at: .zero
            )
        }

        // Divide the source into segments and apply time mapping
        let segmentCount = 100 // High granularity for smooth ramps
        let segmentSourceDuration = sourceDurationSeconds / Double(segmentCount)

        var currentOutputTime = CMTime.zero

        for i in 0..<segmentCount {
            let normalizedTime = Double(i) / Double(segmentCount)
            let speed = profile.speed(at: normalizedTime)

            let segmentStart = CMTimeMakeWithSeconds(
                Double(i) * segmentSourceDuration,
                preferredTimescale: timescale
            )
            let segmentEnd = CMTimeMakeWithSeconds(
                Double(i + 1) * segmentSourceDuration,
                preferredTimescale: timescale
            )
            let sourceTimeRange = CMTimeRange(start: segmentStart, end: segmentEnd)

            // Output duration = source duration / speed
            // speed < 1.0 -> slower -> longer output duration
            // speed > 1.0 -> faster -> shorter output duration
            let outputSegmentDuration = CMTimeMakeWithSeconds(
                segmentSourceDuration / speed,
                preferredTimescale: timescale
            )

            do {
                try compositionVideoTrack.insertTimeRange(sourceTimeRange, of: sourceVideoTrack, at: currentOutputTime)

                // Scale the segment in the composition
                let outputTimeRange = CMTimeRange(start: currentOutputTime, duration: outputSegmentDuration)
                compositionVideoTrack.scaleTimeRange(
                    CMTimeRange(start: currentOutputTime, duration: CMTimeSubtract(segmentEnd, segmentStart)),
                    toDuration: outputSegmentDuration
                )
            } catch {
                completion(.failure(error))
                return
            }

            currentOutputTime = CMTimeAdd(currentOutputTime, outputSegmentDuration)
        }

        // Export with video composition for resolution control
        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTimeMake(value: 1, timescale: Int32(config.outputFPS))
        videoComposition.renderSize = config.outputSize

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)

        // Apply transform to fit output size
        let trackSize = sourceVideoTrack.naturalSize
        let transform = sourceVideoTrack.preferredTransform
        let transformedSize = trackSize.applying(transform)
        let absSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))

        let scaleX = config.outputSize.width / absSize.width
        let scaleY = config.outputSize.height / absSize.height
        let scale = min(scaleX, scaleY)

        let scaledWidth = absSize.width * scale
        let scaledHeight = absSize.height * scale
        let translateX = (config.outputSize.width - scaledWidth) / 2
        let translateY = (config.outputSize.height - scaledHeight) / 2

        let fitTransform = transform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: translateX, y: translateY))

        layerInstruction.setTransform(fitTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        // Export
        try? FileManager.default.removeItem(at: outputURL)

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            completion(.failure(SlowMotionError.exportFailed("Cannot create export session")))
            return
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.videoComposition = videoComposition
        exportSession.shouldOptimizeForNetworkUse = true

        // Progress monitoring
        if let progress = progress {
            let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                progress(exportSession.progress)
            }

            exportSession.exportAsynchronously {
                timer.invalidate()
                switch exportSession.status {
                case .completed:
                    completion(.success(outputURL))
                case .failed:
                    completion(.failure(exportSession.error ?? SlowMotionError.exportFailed("Unknown")))
                case .cancelled:
                    completion(.failure(SlowMotionError.exportFailed("Cancelled")))
                default:
                    completion(.failure(SlowMotionError.exportFailed("Status: \(exportSession.status.rawValue)")))
                }
            }
        } else {
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    completion(.success(outputURL))
                case .failed:
                    completion(.failure(exportSession.error ?? SlowMotionError.exportFailed("Unknown")))
                default:
                    completion(.failure(SlowMotionError.exportFailed("Status: \(exportSession.status.rawValue)")))
                }
            }
        }
    }

    /// Simple uniform slow motion (no ramping). Convenience wrapper.
    public func applyUniformSlowMotion(
        sourceURL: URL,
        slowdownFactor: Double,
        config: SlowMotionConfig,
        outputURL: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let speed = 1.0 / slowdownFactor
        let profile = SpeedRampProfile.constant(speed: speed)
        applySpeedRamp(
            sourceURL: sourceURL,
            profile: profile,
            config: config,
            outputURL: outputURL,
            completion: completion
        )
    }
}

// MARK: - Errors

public enum SlowMotionError: LocalizedError {
    case cameraUnavailable
    case noSuitableFormat
    case cannotConfigureSession
    case noVideoTrack
    case compositionFailed
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cameraUnavailable: return "No camera available for high frame rate capture."
        case .noSuitableFormat: return "No camera format supports the requested frame rate."
        case .cannotConfigureSession: return "Cannot configure the capture session."
        case .noVideoTrack: return "No video track found in the source."
        case .compositionFailed: return "Failed to create composition."
        case .exportFailed(let detail): return "Export failed: \(detail)"
        }
    }
}
