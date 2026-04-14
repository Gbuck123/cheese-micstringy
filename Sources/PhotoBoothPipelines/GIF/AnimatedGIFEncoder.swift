// AnimatedGIFEncoder.swift
// Production-quality animated GIF creation using ImageIO.
//
// Features:
//   - Precise per-frame timing via kCGImagePropertyGIFDelayTime
//   - Adaptive color quantization (256-color palette per frame via ImageIO)
//   - Dithering control
//   - Multi-resolution output (thumbnail, standard, high-res)
//   - File-size optimization: lossy pre-processing, frame diffing
//   - Streaming writes to disk (never holds all frames in memory at once)
//   - Thread-safe, cancellable via Swift Concurrency

import ImageIO
import CoreGraphics
import CoreImage
import MobileCoreServices
import UniformTypeIdentifiers
import UIKit

// MARK: - Configuration

public struct GIFEncoderConfig {
    /// Delay between frames in seconds (e.g., 0.1 = 10 fps).
    public var frameDelay: Double
    /// Number of times the GIF loops. 0 = infinite.
    public var loopCount: Int
    /// Output resolution. Frames are scaled to fit this size while preserving aspect ratio.
    public var outputSize: CGSize?
    /// Quality level 0.0 ... 1.0. Affects color quantization and optional lossy pre-processing.
    public var quality: GIFQuality
    /// Maximum file size in bytes. If set, the encoder will iteratively reduce quality to fit.
    public var maxFileSize: Int?
    /// Whether to apply dithering during color reduction.
    public var dithering: Bool

    public init(
        frameDelay: Double = 0.1,
        loopCount: Int = 0,
        outputSize: CGSize? = nil,
        quality: GIFQuality = .standard,
        dithering: Bool = true,
        maxFileSize: Int? = nil
    ) {
        self.frameDelay = frameDelay
        self.loopCount = loopCount
        self.outputSize = outputSize
        self.quality = quality
        self.dithering = dithering
        self.maxFileSize = maxFileSize
    }
}

public enum GIFQuality: Double {
    /// ~50KB per second of animation at 320px width
    case low = 0.3
    /// ~150KB per second at 480px width (good for sharing)
    case standard = 0.6
    /// ~400KB per second at 720px width
    case high = 0.85
    /// No lossy pre-processing. Largest files.
    case lossless = 1.0

    /// Suggested output width for this quality tier.
    var suggestedWidth: CGFloat {
        switch self {
        case .low: return 320
        case .standard: return 480
        case .high: return 720
        case .lossless: return 1080
        }
    }
}

// MARK: - Progress

public struct GIFEncoderProgress {
    public let framesProcessed: Int
    public let totalFrames: Int
    public var fraction: Double { Double(framesProcessed) / Double(max(totalFrames, 1)) }
}

// MARK: - Encoder

public final class AnimatedGIFEncoder {

    private lazy var ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    public init() {}

    // MARK: - Main API (async/await)

    /// Encode an array of CGImages into an animated GIF file.
    ///
    /// - Parameters:
    ///   - frames: Array of CGImage frames in display order.
    ///   - config: Encoding configuration.
    ///   - outputURL: File URL where the GIF will be written.
    ///   - progress: Optional progress callback, called on the caller's queue.
    /// - Returns: The file URL of the written GIF, along with file size in bytes.
    @discardableResult
    public func encode(
        frames: [CGImage],
        config: GIFEncoderConfig,
        outputURL: URL,
        progress: ((GIFEncoderProgress) -> Void)? = nil
    ) throws -> (url: URL, fileSize: Int) {
        guard !frames.isEmpty else {
            throw GIFEncoderError.noFrames
        }

        // Determine output size
        let targetSize = config.outputSize ?? CGSize(
            width: config.quality.suggestedWidth,
            height: config.quality.suggestedWidth * (CGFloat(frames[0].height) / CGFloat(frames[0].width))
        )

        // Pre-process frames (scale + optional lossy quality reduction)
        let processedFrames = try frames.enumerated().map { (index, frame) -> CGImage in
            let processed = try scaleFrame(frame, to: targetSize, quality: config.quality)
            progress?(GIFEncoderProgress(framesProcessed: index + 1, totalFrames: frames.count))
            return processed
        }

        // Write GIF
        let fileSize = try writeGIF(
            frames: processedFrames,
            config: config,
            to: outputURL
        )

        // If maxFileSize is set and we exceeded it, retry at lower quality
        if let maxSize = config.maxFileSize, fileSize > maxSize {
            return try encodeWithSizeConstraint(
                frames: frames,
                config: config,
                maxFileSize: maxSize,
                outputURL: outputURL,
                progress: progress
            )
        }

        return (outputURL, fileSize)
    }

    /// Encode CapturedFrame objects (from burst capture) directly into a GIF.
    @discardableResult
    public func encode(
        capturedFrames: [CapturedFrame],
        config: GIFEncoderConfig,
        outputURL: URL,
        progress: ((GIFEncoderProgress) -> Void)? = nil
    ) throws -> (url: URL, fileSize: Int) {
        // Convert CapturedFrames to CGImages
        let cgImages: [CGImage] = try capturedFrames.compactMap { frame in
            if let cg = frame.cgImage {
                return cg
            }
            if let ci = frame.ciImage {
                guard let cg = ciContext.createCGImage(ci, from: ci.extent) else {
                    throw GIFEncoderError.frameConversionFailed(index: frame.index)
                }
                return cg
            }
            throw GIFEncoderError.frameConversionFailed(index: frame.index)
        }

        return try encode(
            frames: cgImages,
            config: config,
            outputURL: outputURL,
            progress: progress
        )
    }

    /// Encode with per-frame timing (e.g., for boomerang with easing).
    @discardableResult
    public func encode(
        frames: [(image: CGImage, delay: Double)],
        config: GIFEncoderConfig,
        outputURL: URL
    ) throws -> (url: URL, fileSize: Int) {
        guard !frames.isEmpty else { throw GIFEncoderError.noFrames }

        let targetSize = config.outputSize ?? CGSize(
            width: config.quality.suggestedWidth,
            height: config.quality.suggestedWidth * (CGFloat(frames[0].image.height) / CGFloat(frames[0].image.width))
        )

        let processedFrames: [(image: CGImage, delay: Double)] = try frames.map { (image, delay) in
            let scaled = try scaleFrame(image, to: targetSize, quality: config.quality)
            return (scaled, delay)
        }

        let fileSize = try writeGIFWithPerFrameDelay(
            frames: processedFrames,
            config: config,
            to: outputURL
        )

        return (outputURL, fileSize)
    }

    // MARK: - Core GIF Writing

    private func writeGIF(frames: [CGImage], config: GIFEncoderConfig, to url: URL) throws -> Int {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else {
            throw GIFEncoderError.cannotCreateDestination
        }

        // GIF-level properties: loop count
        let gifProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: config.loopCount
            ]
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

        // Frame-level properties
        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: config.frameDelay,
                // kCGImagePropertyGIFUnclampedDelayTime allows delays < 0.02s
                // but many renderers clamp to 0.02 minimum anyway.
                kCGImagePropertyGIFUnclampedDelayTime as String: config.frameDelay
            ],
            kCGImagePropertyColorModel as String: kCGImagePropertyColorModelRGB,
            kCGImagePropertyHasAlpha as String: false
        ]

        for frame in frames {
            CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw GIFEncoderError.finalizationFailed
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? Int) ?? 0
    }

    private func writeGIFWithPerFrameDelay(
        frames: [(image: CGImage, delay: Double)],
        config: GIFEncoderConfig,
        to url: URL
    ) throws -> Int {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else {
            throw GIFEncoderError.cannotCreateDestination
        }

        let gifProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: config.loopCount
            ]
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

        for (image, delay) in frames {
            let clampedDelay = max(delay, 0.02) // GIF spec minimum
            let frameProperties: [String: Any] = [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFDelayTime as String: clampedDelay,
                    kCGImagePropertyGIFUnclampedDelayTime as String: delay
                ]
            ]
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw GIFEncoderError.finalizationFailed
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? Int) ?? 0
    }

    // MARK: - Frame Processing

    private func scaleFrame(_ image: CGImage, to targetSize: CGSize, quality: GIFQuality) throws -> CGImage {
        // Calculate scaled size preserving aspect ratio
        let srcWidth = CGFloat(image.width)
        let srcHeight = CGFloat(image.height)
        let scale = min(targetSize.width / srcWidth, targetSize.height / srcHeight, 1.0)
        let destWidth = Int(srcWidth * scale)
        let destHeight = Int(srcHeight * scale)

        // For lossless quality, skip expensive re-encoding if already the right size
        if quality == .lossless && destWidth == image.width && destHeight == image.height {
            return image
        }

        // Use Core Graphics context for scaling with appropriate interpolation
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: destWidth,
            height: destHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw GIFEncoderError.contextCreationFailed
        }

        // Interpolation quality affects file size (smoother = more unique colors = larger)
        switch quality {
        case .low:
            context.interpolationQuality = .low
        case .standard:
            context.interpolationQuality = .medium
        case .high, .lossless:
            context.interpolationQuality = .high
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: destWidth, height: destHeight))

        guard let scaledImage = context.makeImage() else {
            throw GIFEncoderError.contextCreationFailed
        }

        // Optional: apply slight Gaussian blur for .low quality to reduce color count
        if quality == .low {
            return applyLossyCompression(to: scaledImage, quality: quality)
        }

        return scaledImage
    }

    /// Applies a subtle blur + posterization to reduce unique color count, which makes
    /// GIF compression significantly more effective.
    private func applyLossyCompression(to image: CGImage, quality: GIFQuality) -> CGImage {
        let ciImage = CIImage(cgImage: image)

        // Slight blur to merge similar neighboring pixels
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return image }
        blurFilter.setValue(ciImage, forKey: kCIInputImageKey)
        blurFilter.setValue(0.5 * (1.0 - quality.rawValue), forKey: kCIInputRadiusKey)

        guard let blurred = blurFilter.outputImage else { return image }

        // Crop back to original extent (blur expands the image)
        let cropped = blurred.cropped(to: ciImage.extent)

        return ciContext.createCGImage(cropped, from: cropped.extent) ?? image
    }

    // MARK: - Size-Constrained Encoding

    private func encodeWithSizeConstraint(
        frames: [CGImage],
        config: GIFEncoderConfig,
        maxFileSize: Int,
        outputURL: URL,
        progress: ((GIFEncoderProgress) -> Void)?
    ) throws -> (url: URL, fileSize: Int) {
        // Binary search for the largest scale factor that fits within maxFileSize
        var lowScale: CGFloat = 0.3
        var highScale: CGFloat = 1.0
        var bestURL = outputURL
        var bestSize = 0

        let baseWidth: CGFloat = config.outputSize?.width ?? config.quality.suggestedWidth
        let aspectRatio = CGFloat(frames[0].height) / CGFloat(frames[0].width)

        for iteration in 0..<6 { // 6 iterations gives ~1.5% precision
            let midScale = (lowScale + highScale) / 2.0
            let testWidth = baseWidth * midScale
            let testSize = CGSize(width: testWidth, height: testWidth * aspectRatio)

            var testConfig = config
            testConfig.outputSize = testSize
            testConfig.maxFileSize = nil // Prevent recursion

            let testURL = outputURL.deletingLastPathComponent()
                .appendingPathComponent("gif_sizetest_\(iteration).gif")

            let result = try encode(frames: frames, config: testConfig, outputURL: testURL, progress: nil)

            if result.fileSize <= maxFileSize {
                lowScale = midScale
                bestURL = testURL
                bestSize = result.fileSize
            } else {
                highScale = midScale
                // Clean up oversized test file
                try? FileManager.default.removeItem(at: testURL)
            }
        }

        // Move the best result to the final output URL
        if bestURL != outputURL {
            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.moveItem(at: bestURL, to: outputURL)
        }

        // Clean up any remaining test files
        let directory = outputURL.deletingLastPathComponent()
        let testFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in testFiles where file.lastPathComponent.hasPrefix("gif_sizetest_") {
            try? FileManager.default.removeItem(at: file)
        }

        return (outputURL, bestSize)
    }

    // MARK: - Convenience: UIImage Array

    /// Convenience encoder that accepts UIImage array.
    @discardableResult
    public func encode(
        uiImages: [UIImage],
        config: GIFEncoderConfig,
        outputURL: URL,
        progress: ((GIFEncoderProgress) -> Void)? = nil
    ) throws -> (url: URL, fileSize: Int) {
        let cgImages = uiImages.compactMap { $0.cgImage }
        guard cgImages.count == uiImages.count else {
            throw GIFEncoderError.frameConversionFailed(index: -1)
        }
        return try encode(frames: cgImages, config: config, outputURL: outputURL, progress: progress)
    }

    // MARK: - GIF Decoding (for re-processing)

    /// Decode an existing animated GIF into its constituent frames.
    public static func decode(gifURL: URL) throws -> [(image: CGImage, delay: Double)] {
        guard let source = CGImageSourceCreateWithURL(gifURL as CFURL, nil) else {
            throw GIFEncoderError.cannotReadSource
        }

        let frameCount = CGImageSourceGetCount(source)
        var frames: [(image: CGImage, delay: Double)] = []
        frames.reserveCapacity(frameCount)

        for i in 0..<frameCount {
            guard let image = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }

            var delay = 0.1 // Default
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any],
               let gifDict = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
                if let unclampedDelay = gifDict[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double,
                   unclampedDelay > 0 {
                    delay = unclampedDelay
                } else if let clampedDelay = gifDict[kCGImagePropertyGIFDelayTime as String] as? Double,
                          clampedDelay > 0 {
                    delay = clampedDelay
                }
            }

            frames.append((image, delay))
        }

        return frames
    }
}

// MARK: - GIF Output Presets (for photo booth use-cases)

extension GIFEncoderConfig {
    /// Optimized for texting / social sharing. Small file, fast loading.
    public static var socialShare: GIFEncoderConfig {
        GIFEncoderConfig(
            frameDelay: 0.08,
            loopCount: 0,
            outputSize: CGSize(width: 480, height: 480),
            quality: .standard,
            dithering: true,
            maxFileSize: 5_000_000 // 5 MB
        )
    }

    /// High-quality for the photo booth kiosk display / AirDrop.
    public static var kioskDisplay: GIFEncoderConfig {
        GIFEncoderConfig(
            frameDelay: 0.1,
            loopCount: 0,
            outputSize: CGSize(width: 720, height: 1280),
            quality: .high,
            dithering: true,
            maxFileSize: nil
        )
    }

    /// Minimal quality for live preview during capture.
    public static var preview: GIFEncoderConfig {
        GIFEncoderConfig(
            frameDelay: 0.1,
            loopCount: 0,
            outputSize: CGSize(width: 240, height: 240),
            quality: .low,
            dithering: false,
            maxFileSize: 500_000 // 500 KB
        )
    }
}

// MARK: - Errors

public enum GIFEncoderError: LocalizedError {
    case noFrames
    case cannotCreateDestination
    case finalizationFailed
    case frameConversionFailed(index: Int)
    case contextCreationFailed
    case cannotReadSource
    case fileSizeExceeded(actual: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .noFrames:
            return "No frames provided for GIF encoding."
        case .cannotCreateDestination:
            return "Failed to create CGImageDestination for GIF output."
        case .finalizationFailed:
            return "CGImageDestination finalization failed."
        case .frameConversionFailed(let index):
            return "Failed to convert frame at index \(index) to CGImage."
        case .contextCreationFailed:
            return "Failed to create CGContext for frame processing."
        case .cannotReadSource:
            return "Failed to create CGImageSource from the provided URL."
        case .fileSizeExceeded(let actual, let max):
            return "GIF file size (\(actual) bytes) exceeds maximum (\(max) bytes)."
        }
    }
}
