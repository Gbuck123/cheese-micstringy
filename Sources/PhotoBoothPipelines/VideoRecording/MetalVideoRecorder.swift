// MetalVideoRecorder.swift
// Records Metal-processed frames to an H.264/HEVC video file using AVAssetWriter.
// Frames are read back from GPU textures to CVPixelBuffers for encoding.

import Foundation
import Metal
import AVFoundation
import CoreVideo
import CoreImage

/// Records a video from Metal-processed textures with applied effects.
///
/// Usage:
/// ```swift
/// let recorder = MetalVideoRecorder(width: 1920, height: 1080)
/// recorder.startRecording(to: fileURL)
/// // Each frame from the camera pipeline:
/// recorder.appendFrame(processedTexture, at: presentationTime)
/// // When done:
/// recorder.stopRecording { url in ... }
/// ```
public final class MetalVideoRecorder {

    // MARK: - Configuration

    public let width: Int
    public let height: Int

    /// Video codec. HEVC is preferred on iPads with Apple Silicon for better compression.
    public var codec: AVVideoCodecType = .hevc

    /// Target bitrate in bits per second. 0 = let the encoder decide.
    public var bitrate: Int = 0

    /// Frame rate for the output video.
    public var frameRate: Int = 30

    /// Whether to include audio (requires separate audio buffer feeding).
    public var includeAudio: Bool = false

    // MARK: - State

    public enum State {
        case idle
        case recording
        case finishing
    }

    public private(set) var state: State = .idle

    // MARK: - Internal

    private let context: MetalContext
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?

    private var pixelBufferPool: CVPixelBufferPool?
    private let writerQueue = DispatchQueue(label: "com.photobooth.videoWriter", qos: .userInitiated)

    private var frameIndex: Int = 0
    private var startTime: CMTime = .zero

    public init(width: Int, height: Int, context: MetalContext = .shared) {
        self.width = width
        self.height = height
        self.context = context
    }

    // MARK: - Recording Lifecycle

    public func startRecording(to url: URL) {
        guard state == .idle else { return }

        // Remove existing file if present.
        try? FileManager.default.removeItem(at: url)

        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            print("[MetalVideoRecorder] Failed to create writer: \(error)")
            return
        }

        // Video settings
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]

        if bitrate > 0 {
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: frameRate
            ]
        }

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput!.expectsMediaDataInRealTime = true

        let pbAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput!,
            sourcePixelBufferAttributes: pbAttributes
        )

        writer!.add(videoInput!)

        // Optional audio input.
        if includeAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128000
            ]
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput!.expectsMediaDataInRealTime = true
            writer!.add(audioInput!)
        }

        writer!.startWriting()
        writer!.startSession(atSourceTime: .zero)

        frameIndex = 0
        state = .recording
    }

    /// Append a Metal-processed texture as a video frame.
    public func appendFrame(_ texture: MTLTexture, at time: CMTime? = nil) {
        guard state == .recording, let input = videoInput, input.isReadyForMoreMediaData else { return }

        let presentationTime = time ?? CMTime(value: CMTimeValue(frameIndex),
                                               timescale: CMTimeScale(frameRate))

        // Convert MTLTexture → CVPixelBuffer.
        guard let pixelBuffer = pixelBufferFromTexture(texture) else { return }

        pixelBufferAdaptor?.append(pixelBuffer, withPresentationTime: presentationTime)
        frameIndex += 1
    }

    /// Append an audio sample buffer (if includeAudio is true).
    public func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard state == .recording, let input = audioInput, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    /// Stop recording and finalize the video file.
    public func stopRecording(completion: @escaping (URL?) -> Void) {
        guard state == .recording else {
            completion(nil)
            return
        }

        state = .finishing

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        writer?.finishWriting { [weak self] in
            let url = self?.writer?.outputURL
            self?.state = .idle
            self?.writer = nil
            self?.videoInput = nil
            self?.audioInput = nil
            self?.pixelBufferAdaptor = nil
            completion(self?.writer?.status == .completed ? url : nil)
        }
    }

    // MARK: - Texture → Pixel Buffer

    private func pixelBufferFromTexture(_ texture: MTLTexture) -> CVPixelBuffer? {
        // Use CIContext for GPU-accelerated texture → pixel buffer conversion.
        let ciImage = CIImage(mtlTexture: texture, options: nil)!

        var pb: CVPixelBuffer?

        // Try to get from the adaptor's pool first (recycled buffers).
        if let pool = pixelBufferAdaptor?.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        }

        // Fallback: create a new pixel buffer.
        if pb == nil {
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width, height,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &pb
            )
        }

        guard let pixelBuffer = pb else { return nil }

        context.ciContext.render(
            ciImage,
            to: pixelBuffer,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return pixelBuffer
    }
}
