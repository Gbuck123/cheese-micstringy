// GIFExporter.swift
// Captures a sequence of Metal-processed frames and exports them as an animated GIF.

import Foundation
import Metal
import CoreImage
import ImageIO
import MobileCoreServices
import UniformTypeIdentifiers

/// Captures frames from the Metal filter chain and exports an animated GIF.
public final class GIFExporter {

    // MARK: - Configuration

    /// Number of frames to capture.
    public var frameCount: Int = 30

    /// Delay between frames in seconds (1/fps).
    public var frameDelay: Double = 1.0 / 15.0

    /// GIF loop count (0 = infinite).
    public var loopCount: Int = 0

    /// Output dimensions. Frames will be scaled to fit.
    public var outputWidth: Int = 480
    public var outputHeight: Int = 360

    // MARK: - Internal

    private let context: MetalContext
    private var frames: [CGImage] = []

    public init(context: MetalContext = .shared) {
        self.context = context
    }

    /// Reset for a new capture.
    public func reset() {
        frames.removeAll()
    }

    /// Add a processed frame. Returns true when enough frames have been collected.
    @discardableResult
    public func addFrame(_ texture: MTLTexture) -> Bool {
        // Convert MTLTexture → CGImage via CIContext.
        let ciImage = CIImage(mtlTexture: texture, options: nil)!
        let scaledImage = ciImage.transformed(by: CGAffineTransform(
            scaleX: CGFloat(outputWidth) / CGFloat(texture.width),
            y: CGFloat(outputHeight) / CGFloat(texture.height)
        ))

        if let cgImage = context.ciContext.createCGImage(
            scaledImage,
            from: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        ) {
            frames.append(cgImage)
        }

        return frames.count >= frameCount
    }

    /// Export the captured frames as an animated GIF.
    /// - Returns: URL to the temporary GIF file, or nil on failure.
    public func export() -> URL? {
        guard frames.count > 0 else { return nil }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("gif")

        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else { return nil }

        // Set GIF-level properties (loop count).
        let gifProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: loopCount
            ]
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

        // Add each frame.
        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: frameDelay
            ]
        ]

        for frame in frames {
            CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else { return nil }

        return tempURL
    }
}
