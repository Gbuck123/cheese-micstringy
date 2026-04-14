// SlowMotionCapture.swift
// Captures high-frame-rate video (120/240fps on supported iPads) and exports
// with time remapping for slow-motion effects.

import Foundation
import AVFoundation
import Metal

/// Configures the camera for high-frame-rate capture and handles time remapping
/// for slow-motion export.
public final class SlowMotionCapture {

    // MARK: - Configuration

    /// Desired high frame rate (120 or 240fps, device-dependent).
    public var targetHFRFrameRate: Int = 120

    /// Slow-motion factor (2x = half speed, 4x = quarter speed).
    public var slowdownFactor: Double = 4.0

    /// Time range (in original-speed seconds) that should be slowed down.
    /// Everything outside this range plays at normal speed.
    public var slowMotionRange: ClosedRange<Double> = 1.0...3.0

    // MARK: - Internal

    private let context: MetalContext

    public init(context: MetalContext = .shared) {
        self.context = context
    }

    /// Find the best high-frame-rate format for the given camera.
    public func bestHFRFormat(for device: AVCaptureDevice) -> (format: AVCaptureDevice.Format, range: AVFrameRateRange)? {
        var bestFormat: AVCaptureDevice.Format?
        var bestRange: AVFrameRateRange?

        for format in device.formats {
            for range in format.videoSupportedFrameRateRanges {
                if range.maxFrameRate >= Double(targetHFRFrameRate) {
                    if bestRange == nil || range.maxFrameRate > bestRange!.maxFrameRate {
                        bestFormat = format
                        bestRange = range
                    }
                }
            }
        }

        guard let format = bestFormat, let range = bestRange else { return nil }
        return (format, range)
    }

    /// Configure the camera device for high-frame-rate capture.
    public func configureHFR(device: AVCaptureDevice) -> Bool {
        guard let (format, range) = bestHFRFormat(for: device) else {
            print("[SlowMotionCapture] No HFR format supporting \(targetHFRFrameRate)fps found.")
            return false
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeVideoMinFrameDuration = range.minFrameDuration
            device.activeVideoMaxFrameDuration = range.minFrameDuration
            device.unlockForConfiguration()
            print("[SlowMotionCapture] Configured HFR: \(range.maxFrameRate)fps")
            return true
        } catch {
            print("[SlowMotionCapture] Failed to configure HFR: \(error)")
            return false
        }
    }

    /// Apply slow-motion time remapping to an AVMutableComposition.
    /// - Parameters:
    ///   - asset: The recorded high-frame-rate video asset.
    ///   - outputURL: Where to write the time-remapped video.
    ///   - completion: Called with the output URL on success, nil on failure.
    public func exportWithSlowMotion(asset: AVAsset,
                                     outputURL: URL,
                                     completion: @escaping (URL?) -> Void) {

        let composition = AVMutableComposition()

        guard let videoTrack = asset.tracks(withMediaType: .video).first,
              let compositionTrack = composition.addMutableTrack(
                  withMediaType: .video,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            completion(nil)
            return
        }

        let duration = asset.duration
        do {
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: videoTrack,
                at: .zero
            )
        } catch {
            completion(nil)
            return
        }

        // Time remapping: slow down the specified range.
        let timescale: CMTimeScale = 600
        let slowStart = CMTime(seconds: slowMotionRange.lowerBound, preferredTimescale: timescale)
        let slowEnd = CMTime(seconds: slowMotionRange.upperBound, preferredTimescale: timescale)
        let slowRange = CMTimeRange(start: slowStart, end: slowEnd)
        let scaledDuration = CMTimeMultiplyByFloat64(slowRange.duration, multiplier: slowdownFactor)

        compositionTrack.scaleTimeRange(slowRange, toDuration: scaledDuration)

        // Export
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            completion(nil)
            return
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4

        exportSession.exportAsynchronously {
            switch exportSession.status {
            case .completed:
                completion(outputURL)
            default:
                print("[SlowMotionCapture] Export failed: \(exportSession.error?.localizedDescription ?? "unknown")")
                completion(nil)
            }
        }
    }
}
