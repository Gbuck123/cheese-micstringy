// VideoTemplateCompositor.swift
// Video template system (VideoFX) using AVVideoCompositing protocol.
//
// Architecture:
//   Template video (with alpha channel or designated regions) is composited with
//   the user's captured video/photos using a custom AVVideoCompositing implementation.
//
// Use cases:
//   - Branded frame overlays that animate (e.g., sparkle borders, sliding text)
//   - Green-screen style keying where template designates replacement regions
//   - Picture-in-picture effects
//   - Split-screen templates
//   - Photo slideshow with animated transitions

import AVFoundation
import CoreImage
import CoreVideo
import UIKit

// MARK: - Template Definition

/// Describes a video template and how user content maps into it.
public struct VideoTemplate {
    /// Unique identifier for the template.
    public let id: String
    /// Human-readable name.
    public let name: String
    /// URL of the template video asset. Should be ProRes 4444 for alpha, or H.264/HEVC for keying.
    public let templateVideoURL: URL
    /// How to composite the user content with the template.
    public let compositeMode: TemplateCompositeMode
    /// Region of the template where user content appears (normalized 0...1).
    /// Only used for `.region` mode.
    public var contentRegion: CGRect
    /// Chroma key color (for `.chromaKey` mode).
    public var chromaKeyColor: CIColor
    /// Chroma key tolerance (0...1).
    public var chromaKeyTolerance: Float
    /// Output resolution.
    public var outputSize: CGSize
    /// Output FPS.
    public var outputFPS: Int

    public init(
        id: String,
        name: String,
        templateVideoURL: URL,
        compositeMode: TemplateCompositeMode = .overlay,
        contentRegion: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        chromaKeyColor: CIColor = CIColor(red: 0, green: 1, blue: 0), // Green screen
        chromaKeyTolerance: Float = 0.3,
        outputSize: CGSize = CGSize(width: 1080, height: 1920),
        outputFPS: Int = 30
    ) {
        self.id = id
        self.name = name
        self.templateVideoURL = templateVideoURL
        self.compositeMode = compositeMode
        self.contentRegion = contentRegion
        self.chromaKeyColor = chromaKeyColor
        self.chromaKeyTolerance = chromaKeyTolerance
        self.outputSize = outputSize
        self.outputFPS = outputFPS
    }
}

public enum TemplateCompositeMode {
    /// Template renders ON TOP of user content (template has alpha channel).
    case overlay
    /// User content renders ON TOP of template.
    case underlay
    /// User content fills a specific region of the template (picture-in-picture).
    case region
    /// Chroma key: template's green (or specified color) areas are replaced by user content.
    case chromaKey
    /// Side-by-side or custom layout defined by a compositor class.
    case custom(CustomCompositorFactory)
}

/// Factory protocol for creating custom compositors.
public protocol CustomCompositorFactory {
    func makeCompositor() -> AVVideoCompositing
}

// MARK: - Template Compositor Engine

public final class VideoTemplateEngine {

    private lazy var ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext()
    }()

    public init() {}

    // MARK: - Video + Video Compositing

    /// Composite a user video with a template video.
    public func compose(
        userVideoURL: URL,
        template: VideoTemplate,
        outputURL: URL,
        progress: ((Float) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let templateAsset = AVURLAsset(url: template.templateVideoURL)
        let userAsset = AVURLAsset(url: userVideoURL)

        guard let templateVideoTrack = templateAsset.tracks(withMediaType: .video).first,
              let userVideoTrack = userAsset.tracks(withMediaType: .video).first else {
            completion(.failure(VideoFXError.missingVideoTrack))
            return
        }

        let duration = min(templateAsset.duration, userAsset.duration)

        // Build composition
        let composition = AVMutableComposition()

        // Track A: User content
        guard let compTrackA = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: 1
        ) else {
            completion(.failure(VideoFXError.compositionFailed))
            return
        }
        try? compTrackA.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: userVideoTrack,
            at: .zero
        )

        // Track B: Template
        guard let compTrackB = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: 2
        ) else {
            completion(.failure(VideoFXError.compositionFailed))
            return
        }
        try? compTrackB.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: templateVideoTrack,
            at: .zero
        )

        // Audio from user video
        if let userAudioTrack = userAsset.tracks(withMediaType: .audio).first {
            if let compAudio = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) {
                try? compAudio.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: userAudioTrack,
                    at: .zero
                )
            }
        }

        // Audio from template (if any)
        if let templateAudioTrack = templateAsset.tracks(withMediaType: .audio).first {
            if let compTemplateAudio = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) {
                try? compTemplateAudio.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: templateAudioTrack,
                    at: .zero
                )
            }
        }

        // Build custom video composition
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = template.outputSize
        videoComposition.frameDuration = CMTimeMake(value: 1, timescale: Int32(template.outputFPS))

        // Use our custom compositor
        videoComposition.customVideoCompositorClass = TemplateVideoCompositor.self

        // Set up instruction
        let instruction = TemplateCompositionInstruction(
            timeRange: CMTimeRange(start: .zero, duration: duration),
            userTrackID: compTrackA.trackID,
            templateTrackID: compTrackB.trackID,
            template: template
        )
        videoComposition.instructions = [instruction]

        // Export
        try? FileManager.default.removeItem(at: outputURL)

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            completion(.failure(VideoFXError.exportFailed("Cannot create export session")))
            return
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.videoComposition = videoComposition
        exportSession.shouldOptimizeForNetworkUse = true

        // Progress timer
        var progressTimer: Timer?
        if let progress = progress {
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                progress(exportSession.progress)
            }
        }

        exportSession.exportAsynchronously {
            progressTimer?.invalidate()
            switch exportSession.status {
            case .completed:
                completion(.success(outputURL))
            case .failed:
                completion(.failure(exportSession.error ?? VideoFXError.exportFailed("Unknown")))
            default:
                completion(.failure(VideoFXError.exportFailed("Status: \(exportSession.status.rawValue)")))
            }
        }
    }

    // MARK: - Photos + Template Video (Slideshow)

    /// Create a video from photos composited with a template.
    /// Each photo is shown for `photoDuration` seconds.
    public func composePhotosWithTemplate(
        photos: [UIImage],
        photoDuration: TimeInterval = 3.0,
        template: VideoTemplate,
        outputURL: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let totalDuration = photoDuration * Double(photos.count)
        let fps = template.outputFPS
        let size = template.outputSize

        // First, create a video from the photos
        let photoVideoURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("photos_temp.mp4")

        do {
            try createVideoFromPhotos(
                photos: photos,
                photoDuration: photoDuration,
                fps: fps,
                size: size,
                outputURL: photoVideoURL
            )

            // Now composite with the template
            compose(
                userVideoURL: photoVideoURL,
                template: template,
                outputURL: outputURL,
                completion: { result in
                    // Clean up temp file
                    try? FileManager.default.removeItem(at: photoVideoURL)
                    completion(result)
                }
            )
        } catch {
            completion(.failure(error))
        }
    }

    /// Create a video from a sequence of photos (for use as input to template compositing).
    private func createVideoFromPhotos(
        photos: [UIImage],
        photoDuration: TimeInterval,
        fps: Int,
        size: CGSize,
        outputURL: URL
    ) throws {
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoMaxKeyFrameIntervalKey: fps
            ]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )

        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frameDuration = CMTimeMake(value: 1, timescale: Int32(fps))
        let framesPerPhoto = Int(photoDuration * Double(fps))

        var frameIndex = 0
        for photo in photos {
            guard let cgImage = photo.cgImage else { continue }

            let pixelBuffer = createPixelBuffer(from: cgImage, size: size)
            guard let buffer = pixelBuffer else { continue }

            for _ in 0..<framesPerPhoto {
                while !input.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                let time = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
                adaptor.append(buffer, withPresentationTime: time)
                frameIndex += 1
            }
        }

        input.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()

        guard writer.status == .completed else {
            throw VideoFXError.exportFailed(writer.error?.localizedDescription ?? "Unknown")
        }
    }

    private func createPixelBuffer(from image: CGImage, size: CGSize) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width), Int(size.height),
            kCVPixelFormatType_32ARGB,
            [kCVPixelBufferCGImageCompatibilityKey: true,
             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &pixelBuffer
        )
        guard let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return buffer
    }
}

// MARK: - Custom Video Compositor (AVVideoCompositing)

/// The custom compositor that merges template and user video frames.
public final class TemplateVideoCompositor: NSObject, AVVideoCompositing {

    // Required properties
    public var sourcePixelBufferAttributes: [String: Any]? {
        return [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    public var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        return [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    public var supportsWideColorSourceFrames: Bool { true }
    public var supportsHDRSourceFrames: Bool { false }

    private var renderContext: AVVideoCompositionRenderContext?
    private let renderQueue = DispatchQueue(label: "com.photobooth.templatecompositor.render", qos: .userInitiated)

    private lazy var ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext()
    }()

    // MARK: - AVVideoCompositing

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderQueue.sync {
            self.renderContext = newRenderContext
        }
    }

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            guard let self = self else {
                request.finish(with: VideoFXError.compositorDeallocated)
                return
            }

            guard let instruction = request.videoCompositionInstruction as? TemplateCompositionInstruction else {
                request.finish(with: VideoFXError.invalidInstruction)
                return
            }

            // Get source frames
            guard let userPixelBuffer = request.sourceFrame(byTrackID: instruction.userTrackID),
                  let templatePixelBuffer = request.sourceFrame(byTrackID: instruction.templateTrackID) else {
                request.finish(with: VideoFXError.missingSourceFrame)
                return
            }

            let userImage = CIImage(cvPixelBuffer: userPixelBuffer)
            let templateImage = CIImage(cvPixelBuffer: templatePixelBuffer)
            let outputSize = instruction.template.outputSize

            // Composite based on mode
            let composited: CIImage
            switch instruction.template.compositeMode {
            case .overlay:
                composited = self.compositeOverlay(
                    user: userImage,
                    template: templateImage,
                    outputSize: outputSize
                )

            case .underlay:
                composited = self.compositeUnderlay(
                    user: userImage,
                    template: templateImage,
                    outputSize: outputSize
                )

            case .region:
                composited = self.compositeRegion(
                    user: userImage,
                    template: templateImage,
                    region: instruction.template.contentRegion,
                    outputSize: outputSize
                )

            case .chromaKey:
                composited = self.compositeChromaKey(
                    user: userImage,
                    template: templateImage,
                    keyColor: instruction.template.chromaKeyColor,
                    tolerance: instruction.template.chromaKeyTolerance,
                    outputSize: outputSize
                )

            case .custom:
                // Custom mode would use the factory-provided compositor instead
                composited = self.compositeOverlay(
                    user: userImage,
                    template: templateImage,
                    outputSize: outputSize
                )
            }

            // Render to output pixel buffer
            guard let outputBuffer = request.renderContext.newPixelBuffer() else {
                request.finish(with: VideoFXError.cannotCreateOutputBuffer)
                return
            }

            self.ciContext.render(composited, to: outputBuffer)
            request.finish(withComposedVideoFrame: outputBuffer)
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {
        renderQueue.async {
            // Nothing to cancel; each request is processed synchronously on the render queue
        }
    }

    // MARK: - Compositing Modes

    /// Template overlays on top of user content (template has alpha).
    private func compositeOverlay(user: CIImage, template: CIImage, outputSize: CGSize) -> CIImage {
        let scaledUser = scaleToFill(image: user, size: outputSize)
        let scaledTemplate = scaleToFill(image: template, size: outputSize)

        guard let filter = CIFilter(name: "CISourceOverCompositing") else { return scaledUser }
        filter.setValue(scaledTemplate, forKey: kCIInputImageKey)
        filter.setValue(scaledUser, forKey: kCIInputBackgroundImageKey)

        return filter.outputImage?.cropped(to: CGRect(origin: .zero, size: outputSize)) ?? scaledUser
    }

    /// User content overlays on top of template.
    private func compositeUnderlay(user: CIImage, template: CIImage, outputSize: CGSize) -> CIImage {
        let scaledUser = scaleToFill(image: user, size: outputSize)
        let scaledTemplate = scaleToFill(image: template, size: outputSize)

        guard let filter = CIFilter(name: "CISourceOverCompositing") else { return scaledUser }
        filter.setValue(scaledUser, forKey: kCIInputImageKey)
        filter.setValue(scaledTemplate, forKey: kCIInputBackgroundImageKey)

        return filter.outputImage?.cropped(to: CGRect(origin: .zero, size: outputSize)) ?? scaledUser
    }

    /// User content fills a specific region within the template.
    private func compositeRegion(
        user: CIImage,
        template: CIImage,
        region: CGRect,
        outputSize: CGSize
    ) -> CIImage {
        let scaledTemplate = scaleToFill(image: template, size: outputSize)

        // Scale and position user content into the region
        let regionPixels = CGRect(
            x: region.origin.x * outputSize.width,
            y: region.origin.y * outputSize.height,
            width: region.width * outputSize.width,
            height: region.height * outputSize.height
        )

        let userExtent = user.extent
        let scaleX = regionPixels.width / userExtent.width
        let scaleY = regionPixels.height / userExtent.height
        let scale = max(scaleX, scaleY) // Aspect fill

        var scaledUser = user
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Center in region
        let scaledExtent = scaledUser.extent
        let offsetX = regionPixels.midX - scaledExtent.midX
        let offsetY = regionPixels.midY - scaledExtent.midY
        scaledUser = scaledUser.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))

        // Crop to region
        scaledUser = scaledUser.cropped(to: regionPixels)

        // Composite: user behind template
        guard let compositeFilter = CIFilter(name: "CISourceOverCompositing") else { return scaledTemplate }
        compositeFilter.setValue(scaledTemplate, forKey: kCIInputImageKey)
        compositeFilter.setValue(scaledUser, forKey: kCIInputBackgroundImageKey)

        return compositeFilter.outputImage?.cropped(to: CGRect(origin: .zero, size: outputSize)) ?? scaledTemplate
    }

    /// Replace chroma key color in template with user content.
    private func compositeChromaKey(
        user: CIImage,
        template: CIImage,
        keyColor: CIColor,
        tolerance: Float,
        outputSize: CGSize
    ) -> CIImage {
        let scaledUser = scaleToFill(image: user, size: outputSize)
        let scaledTemplate = scaleToFill(image: template, size: outputSize)

        // Create a chroma key mask using CIColorCube
        // This replaces pixels matching the key color with transparency
        let maskedTemplate = applyChromaKey(
            to: scaledTemplate,
            keyColor: keyColor,
            tolerance: tolerance
        )

        // Composite: masked template over user content
        guard let filter = CIFilter(name: "CISourceOverCompositing") else { return scaledUser }
        filter.setValue(maskedTemplate, forKey: kCIInputImageKey)
        filter.setValue(scaledUser, forKey: kCIInputBackgroundImageKey)

        return filter.outputImage?.cropped(to: CGRect(origin: .zero, size: outputSize)) ?? scaledUser
    }

    /// Apply chroma key removal using CIColorCube.
    private func applyChromaKey(to image: CIImage, keyColor: CIColor, tolerance: Float) -> CIImage {
        // Build a 3D color lookup table that maps the key color to transparent
        let cubeSize = 64
        let cubeDataSize = cubeSize * cubeSize * cubeSize * 4
        var cubeData = [Float](repeating: 0, count: cubeDataSize)

        let keyR = Float(keyColor.red)
        let keyG = Float(keyColor.green)
        let keyB = Float(keyColor.blue)

        var offset = 0
        for z in 0..<cubeSize {
            let blue = Float(z) / Float(cubeSize - 1)
            for y in 0..<cubeSize {
                let green = Float(y) / Float(cubeSize - 1)
                for x in 0..<cubeSize {
                    let red = Float(x) / Float(cubeSize - 1)

                    // Distance from key color in RGB space
                    let distance = sqrt(
                        pow(red - keyR, 2) +
                        pow(green - keyG, 2) +
                        pow(blue - keyB, 2)
                    )

                    // Smooth falloff
                    let alpha: Float
                    if distance < tolerance {
                        alpha = 0.0
                    } else if distance < tolerance * 1.5 {
                        alpha = (distance - tolerance) / (tolerance * 0.5)
                    } else {
                        alpha = 1.0
                    }

                    // Premultiplied alpha
                    cubeData[offset] = red * alpha
                    cubeData[offset + 1] = green * alpha
                    cubeData[offset + 2] = blue * alpha
                    cubeData[offset + 3] = alpha

                    offset += 4
                }
            }
        }

        let data = Data(bytes: cubeData, count: cubeDataSize * MemoryLayout<Float>.size)

        guard let filter = CIFilter(name: "CIColorCube") else { return image }
        filter.setValue(cubeSize, forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")
        filter.setValue(image, forKey: kCIInputImageKey)

        return filter.outputImage ?? image
    }

    // MARK: - Image Scaling

    private func scaleToFill(image: CIImage, size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        let scaleX = size.width / extent.width
        let scaleY = size.height / extent.height
        let scale = max(scaleX, scaleY)

        var scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Center
        let scaledExtent = scaled.extent
        let offsetX = (size.width - scaledExtent.width) / 2 - scaledExtent.origin.x
        let offsetY = (size.height - scaledExtent.height) / 2 - scaledExtent.origin.y
        scaled = scaled.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))

        return scaled.cropped(to: CGRect(origin: .zero, size: size))
    }
}

// MARK: - Custom Composition Instruction

/// Our custom instruction that carries template metadata to the compositor.
public final class TemplateCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    public var timeRange: CMTimeRange
    public var enablePostProcessing: Bool = false
    public var containsTweenableInstruction: Bool = true
    public var requiredSourceTrackIDs: [NSValue]?
    public var passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    public let userTrackID: CMPersistentTrackID
    public let templateTrackID: CMPersistentTrackID
    public let template: VideoTemplate

    public init(
        timeRange: CMTimeRange,
        userTrackID: CMPersistentTrackID,
        templateTrackID: CMPersistentTrackID,
        template: VideoTemplate
    ) {
        self.timeRange = timeRange
        self.userTrackID = userTrackID
        self.templateTrackID = templateTrackID
        self.template = template
        self.requiredSourceTrackIDs = [
            NSValue(bytes: &userTrackID, objCType: "i"),
            NSValue(bytes: &templateTrackID, objCType: "i")
        ]
        super.init()

        // Properly set up the required source track IDs as NSNumber
        self.requiredSourceTrackIDs = [
            NSNumber(value: userTrackID),
            NSNumber(value: templateTrackID)
        ]
    }
}

// MARK: - Errors

public enum VideoFXError: LocalizedError {
    case missingVideoTrack
    case compositionFailed
    case exportFailed(String)
    case invalidInstruction
    case missingSourceFrame
    case cannotCreateOutputBuffer
    case compositorDeallocated

    public var errorDescription: String? {
        switch self {
        case .missingVideoTrack: return "Source asset has no video track."
        case .compositionFailed: return "Failed to create composition."
        case .exportFailed(let detail): return "Export failed: \(detail)"
        case .invalidInstruction: return "Invalid composition instruction."
        case .missingSourceFrame: return "Source frame not available."
        case .cannotCreateOutputBuffer: return "Cannot create output pixel buffer."
        case .compositorDeallocated: return "Compositor was deallocated during rendering."
        }
    }
}
