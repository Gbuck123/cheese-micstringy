// BoomerangCapture.swift
// Captures a short burst of Metal-processed frames and plays them forward + reverse
// (boomerang style), exporting as a looping video or GIF.

import Foundation
import Metal
import AVFoundation
import CoreImage

/// Captures frames for a boomerang effect: plays forward then backward in a loop.
public final class BoomerangCapture {

    // MARK: - Configuration

    /// Duration of the forward segment in seconds.
    public var duration: Double = 1.5

    /// Capture frame rate.
    public var captureRate: Int = 30

    /// Output dimensions.
    public var outputWidth: Int = 720
    public var outputHeight: Int = 1280

    /// Speed multiplier (1.0 = normal, 1.5 = faster).
    public var speedMultiplier: Double = 1.2

    // MARK: - Internal

    private let context: MetalContext
    private var frameTextures: [MTLTexture] = []
    private var targetFrameCount: Int { Int(duration * Double(captureRate)) }

    public init(context: MetalContext = .shared) {
        self.context = context
    }

    public func reset() {
        frameTextures.removeAll()
    }

    /// Add a processed frame. Returns true when enough frames are captured.
    @discardableResult
    public func addFrame(_ texture: MTLTexture) -> Bool {
        // Copy to a persistent texture (the source may be recycled).
        let copy = context.makeTexture(width: texture.width, height: texture.height)
        let cmd = context.makeCommandBuffer(label: "Boomerang_Copy")
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.copy(
                from: texture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: .init(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                to: copy, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: .init(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()

        frameTextures.append(copy)
        return frameTextures.count >= targetFrameCount
    }

    /// Returns the boomerang sequence: forward + reversed frames.
    public var boomerangSequence: [MTLTexture] {
        return frameTextures + frameTextures.reversed()
    }

    /// Export the boomerang as a looping MP4 video.
    public func exportVideo(to outputURL: URL, completion: @escaping (Bool) -> Void) {
        let sequence = boomerangSequence
        guard !sequence.isEmpty else {
            completion(false)
            return
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            print("[BoomerangCapture] AVAssetWriter error: \(error)")
            completion(false)
            return
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight
            ]
        )

        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(Double(captureRate) * speedMultiplier))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            for (index, texture) in sequence.enumerated() {
                while !writerInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.01)
                }

                if let pixelBuffer = self.pixelBuffer(from: texture) {
                    let time = CMTimeMultiply(frameDuration, multiplier: Int32(index))
                    adaptor.append(pixelBuffer, withPresentationTime: time)
                }
            }

            writerInput.markAsFinished()
            writer.finishWriting {
                completion(writer.status == .completed)
            }
        }
    }

    // MARK: - Helpers

    private func pixelBuffer(from texture: MTLTexture) -> CVPixelBuffer? {
        let ciImage = CIImage(mtlTexture: texture, options: nil)!
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            texture.width, texture.height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pb
        )
        guard let pixelBuffer = pb else { return nil }
        context.ciContext.render(ciImage, to: pixelBuffer)
        return pixelBuffer
    }
}
