// PhotoStripCompositor.swift
// Multi-shot photo strip pipeline: capture 3-4 photos in sequence with countdown,
// then composite into a vertical or horizontal strip using Core Graphics.
//
// Features:
//   - Configurable layout (vertical, horizontal, 2x2 grid)
//   - Per-photo countdown timer with delegate callbacks
//   - Branded borders, padding, background colors/images
//   - Logo/watermark placement
//   - Date/event stamp text rendering
//   - Output as UIImage, CGImage, or saved to file (JPEG/PNG)

import AVFoundation
import CoreGraphics
import CoreImage
import CoreText
import UIKit

// MARK: - Configuration

public struct PhotoStripConfig {
    /// Number of photos in the strip.
    public var photoCount: Int
    /// Countdown seconds before each photo capture.
    public var countdownSeconds: Int
    /// Delay between consecutive captures (after flash / after save).
    public var interCaptureDelay: TimeInterval
    /// Layout direction.
    public var layout: StripLayout
    /// Output resolution for each individual photo cell.
    public var cellSize: CGSize
    /// Padding between photos in points.
    public var cellPadding: CGFloat
    /// Outer margin around the entire strip.
    public var outerMargin: CGFloat
    /// Background color behind the strip.
    public var backgroundColor: UIColor
    /// Optional background image (e.g., branded template).
    public var backgroundImage: UIImage?
    /// Corner radius for each photo cell.
    public var cellCornerRadius: CGFloat
    /// Border around each cell.
    public var cellBorderWidth: CGFloat
    public var cellBorderColor: UIColor
    /// Optional logo to place at the bottom/side of the strip.
    public var logo: UIImage?
    /// Logo height in points (width computed from aspect ratio).
    public var logoHeight: CGFloat
    /// Text stamp (e.g., event name, date).
    public var stampText: String?
    public var stampFont: UIFont
    public var stampColor: UIColor
    /// Camera position.
    public var cameraPosition: AVCaptureDevice.Position
    /// Output JPEG quality (0.0 ... 1.0). Use 0 for PNG output.
    public var jpegQuality: CGFloat

    public init(
        photoCount: Int = 4,
        countdownSeconds: Int = 3,
        interCaptureDelay: TimeInterval = 0.5,
        layout: StripLayout = .vertical,
        cellSize: CGSize = CGSize(width: 600, height: 400),
        cellPadding: CGFloat = 20,
        outerMargin: CGFloat = 30,
        backgroundColor: UIColor = .white,
        backgroundImage: UIImage? = nil,
        cellCornerRadius: CGFloat = 12,
        cellBorderWidth: CGFloat = 0,
        cellBorderColor: UIColor = .black,
        logo: UIImage? = nil,
        logoHeight: CGFloat = 60,
        stampText: String? = nil,
        stampFont: UIFont = .systemFont(ofSize: 24, weight: .medium),
        stampColor: UIColor = .darkGray,
        cameraPosition: AVCaptureDevice.Position = .front,
        jpegQuality: CGFloat = 0.92
    ) {
        self.photoCount = photoCount
        self.countdownSeconds = countdownSeconds
        self.interCaptureDelay = interCaptureDelay
        self.layout = layout
        self.cellSize = cellSize
        self.cellPadding = cellPadding
        self.outerMargin = outerMargin
        self.backgroundColor = backgroundColor
        self.backgroundImage = backgroundImage
        self.cellCornerRadius = cellCornerRadius
        self.cellBorderWidth = cellBorderWidth
        self.cellBorderColor = cellBorderColor
        self.logo = logo
        self.logoHeight = logoHeight
        self.stampText = stampText
        self.stampFont = stampFont
        self.stampColor = stampColor
        self.cameraPosition = cameraPosition
        self.jpegQuality = jpegQuality
    }

    // MARK: - Presets

    /// Classic 4-up vertical photo strip (like a mall photo booth).
    public static var classic4Up: PhotoStripConfig {
        PhotoStripConfig(
            photoCount: 4,
            countdownSeconds: 3,
            interCaptureDelay: 0.5,
            layout: .vertical,
            cellSize: CGSize(width: 600, height: 400),
            cellPadding: 16,
            outerMargin: 24,
            backgroundColor: .white,
            cellCornerRadius: 0, // Classic strips have square cells
            cellBorderWidth: 2,
            cellBorderColor: .black
        )
    }

    /// 3-photo horizontal strip.
    public static var horizontal3: PhotoStripConfig {
        PhotoStripConfig(
            photoCount: 3,
            layout: .horizontal,
            cellSize: CGSize(width: 400, height: 600),
            cellPadding: 16,
            outerMargin: 24
        )
    }

    /// 2x2 grid layout.
    public static var grid2x2: PhotoStripConfig {
        PhotoStripConfig(
            photoCount: 4,
            layout: .grid(columns: 2),
            cellSize: CGSize(width: 540, height: 540),
            cellPadding: 12,
            outerMargin: 20
        )
    }
}

public enum StripLayout: Equatable {
    case vertical
    case horizontal
    case grid(columns: Int)
}

// MARK: - Delegate

public protocol PhotoStripCaptureDelegate: AnyObject {
    /// Countdown tick. Called each second. `remaining` is seconds until capture.
    func photoStrip(_ compositor: PhotoStripCompositor, countdownTick remaining: Int, forPhoto index: Int)
    /// Called immediately after each photo is captured.
    func photoStrip(_ compositor: PhotoStripCompositor, didCapturePhoto image: UIImage, atIndex index: Int)
    /// Called when all photos are captured and compositing begins.
    func photoStripWillComposite(_ compositor: PhotoStripCompositor)
    /// Called with the final composited strip.
    func photoStrip(_ compositor: PhotoStripCompositor, didFinishWith stripImage: UIImage)
    /// Called on error.
    func photoStrip(_ compositor: PhotoStripCompositor, didFailWith error: Error)
}

// MARK: - Compositor

public final class PhotoStripCompositor {

    public weak var delegate: PhotoStripCaptureDelegate?
    public private(set) var isCaptureInProgress = false

    private var capturedPhotos: [UIImage] = []
    private var photoOutput: AVCapturePhotoOutput?
    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.photobooth.photostrip.session", qos: .userInitiated)

    public init() {}

    // MARK: - Full Pipeline: Capture + Composite

    /// Start the multi-photo capture sequence. This runs the full pipeline:
    /// countdown -> capture -> repeat -> composite -> deliver.
    public func startCapture(config: PhotoStripConfig) {
        guard !isCaptureInProgress else { return }
        isCaptureInProgress = true
        capturedPhotos.removeAll()

        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.setupCaptureSession(config: config)
                self.captureSession.startRunning()
                self.captureSequence(config: config, currentIndex: 0)
            } catch {
                DispatchQueue.main.async {
                    self.delegate?.photoStrip(self, didFailWith: error)
                }
            }
        }
    }

    /// Cancel an in-progress capture.
    public func cancelCapture() {
        isCaptureInProgress = false
        capturedPhotos.removeAll()
        captureSession.stopRunning()
    }

    // MARK: - Compositing Only (from existing photos)

    /// Composite pre-existing photos into a strip. No capture involved.
    public func composite(photos: [UIImage], config: PhotoStripConfig) throws -> UIImage {
        guard photos.count > 0 else { throw PhotoStripError.noPhotos }
        return try renderStrip(photos: photos, config: config)
    }

    /// Composite and save to file.
    public func compositeAndSave(
        photos: [UIImage],
        config: PhotoStripConfig,
        outputURL: URL
    ) throws -> URL {
        let strip = try composite(photos: photos, config: config)

        let data: Data?
        if config.jpegQuality > 0 {
            data = strip.jpegData(compressionQuality: config.jpegQuality)
        } else {
            data = strip.pngData()
        }

        guard let imageData = data else {
            throw PhotoStripError.encodingFailed
        }

        try imageData.write(to: outputURL)
        return outputURL
    }

    // MARK: - Session Setup

    private func setupCaptureSession(config: PhotoStripConfig) throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }

        if captureSession.canSetSessionPreset(.photo) {
            captureSession.sessionPreset = .photo
        }

        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: config.cameraPosition
        ) else {
            throw PhotoStripError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard captureSession.canAddInput(input) else {
            throw PhotoStripError.cannotConfigureSession
        }
        captureSession.addInput(input)

        let output = AVCapturePhotoOutput()
        output.isHighResolutionCaptureEnabled = true
        guard captureSession.canAddOutput(output) else {
            throw PhotoStripError.cannotConfigureSession
        }
        captureSession.addOutput(output)
        self.photoOutput = output
    }

    // MARK: - Capture Sequence

    private func captureSequence(config: PhotoStripConfig, currentIndex: Int) {
        guard isCaptureInProgress, currentIndex < config.photoCount else {
            // All photos captured; composite
            finishCapture(config: config)
            return
        }

        // Countdown
        runCountdown(seconds: config.countdownSeconds, photoIndex: currentIndex) { [weak self] in
            guard let self = self, self.isCaptureInProgress else { return }
            self.capturePhoto(config: config, index: currentIndex)
        }
    }

    private func runCountdown(seconds: Int, photoIndex: Int, completion: @escaping () -> Void) {
        var remaining = seconds

        func tick() {
            guard isCaptureInProgress else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.photoStrip(self, countdownTick: remaining, forPhoto: photoIndex)
            }

            if remaining <= 0 {
                completion()
                return
            }

            remaining -= 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                tick()
            }
        }

        tick()
    }

    private func capturePhoto(config: PhotoStripConfig, index: Int) {
        guard let output = photoOutput else { return }

        let settings = AVCapturePhotoSettings()
        settings.isHighResolutionPhotoEnabled = true

        // Use HEIF if available for better quality per byte
        if output.availablePhotoCodecTypes.contains(.hevc) {
            let heifSettings = AVCapturePhotoSettings(
                format: [AVVideoCodecKey: AVVideoCodecType.hevc]
            )
            heifSettings.isHighResolutionPhotoEnabled = true
        }

        let photoCaptureHandler = PhotoCaptureHandler { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let image):
                self.capturedPhotos.append(image)
                DispatchQueue.main.async {
                    self.delegate?.photoStrip(self, didCapturePhoto: image, atIndex: index)
                }

                // Schedule next capture after inter-capture delay
                DispatchQueue.main.asyncAfter(deadline: .now() + config.interCaptureDelay) {
                    self.sessionQueue.async {
                        self.captureSequence(config: config, currentIndex: index + 1)
                    }
                }

            case .failure(let error):
                DispatchQueue.main.async {
                    self.delegate?.photoStrip(self, didFailWith: error)
                }
            }
        }

        output.capturePhoto(with: settings, delegate: photoCaptureHandler)

        // Prevent handler from being deallocated during capture
        objc_setAssociatedObject(output, "photoCaptureHandler_\(index)", photoCaptureHandler, .OBJC_ASSOCIATION_RETAIN)
    }

    private func finishCapture(config: PhotoStripConfig) {
        isCaptureInProgress = false
        captureSession.stopRunning()

        let photos = capturedPhotos

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.photoStripWillComposite(self)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let strip = try self.renderStrip(photos: photos, config: config)
                DispatchQueue.main.async {
                    self.delegate?.photoStrip(self, didFinishWith: strip)
                }
            } catch {
                DispatchQueue.main.async {
                    self.delegate?.photoStrip(self, didFailWith: error)
                }
            }
        }
    }

    // MARK: - Strip Rendering

    private func renderStrip(photos: [UIImage], config: PhotoStripConfig) throws -> UIImage {
        let stripSize = calculateStripSize(config: config, photoCount: photos.count)
        let cellRects = calculateCellRects(config: config, photoCount: photos.count, stripSize: stripSize)

        // Create drawing context at the full strip resolution
        UIGraphicsBeginImageContextWithOptions(stripSize, true, 1.0)
        guard let context = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            throw PhotoStripError.contextCreationFailed
        }

        // Draw background
        if let bgImage = config.backgroundImage {
            bgImage.draw(in: CGRect(origin: .zero, size: stripSize))
        } else {
            context.setFillColor(config.backgroundColor.cgColor)
            context.fill(CGRect(origin: .zero, size: stripSize))
        }

        // Draw each photo cell
        for (index, rect) in cellRects.enumerated() {
            guard index < photos.count else { break }
            let photo = photos[index]

            // Save context state for clipping
            context.saveGState()

            // Create rounded rect path for the cell
            let cellPath = UIBezierPath(roundedRect: rect, cornerRadius: config.cellCornerRadius)
            cellPath.addClip()

            // Draw the photo, aspect-filling the cell
            let photoRect = aspectFillRect(for: photo.size, in: rect)
            photo.draw(in: photoRect)

            context.restoreGState()

            // Draw border if configured
            if config.cellBorderWidth > 0 {
                context.saveGState()
                context.setStrokeColor(config.cellBorderColor.cgColor)
                context.setLineWidth(config.cellBorderWidth)
                let borderPath = UIBezierPath(roundedRect: rect.insetBy(
                    dx: config.cellBorderWidth / 2,
                    dy: config.cellBorderWidth / 2
                ), cornerRadius: config.cellCornerRadius)
                borderPath.stroke()
                context.restoreGState()
            }
        }

        // Draw logo
        if let logo = config.logo {
            let logoAspect = logo.size.width / logo.size.height
            let logoW = config.logoHeight * logoAspect
            let logoRect = CGRect(
                x: (stripSize.width - logoW) / 2,
                y: stripSize.height - config.outerMargin - config.logoHeight,
                width: logoW,
                height: config.logoHeight
            )
            logo.draw(in: logoRect)
        }

        // Draw stamp text
        if let stampText = config.stampText, !stampText.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: config.stampFont,
                .foregroundColor: config.stampColor
            ]
            let textSize = (stampText as NSString).size(withAttributes: attributes)
            let textOrigin = CGPoint(
                x: (stripSize.width - textSize.width) / 2,
                y: stripSize.height - config.outerMargin - (config.logo != nil ? config.logoHeight + 10 : 0) - textSize.height
            )
            (stampText as NSString).draw(at: textOrigin, withAttributes: attributes)
        }

        guard let result = UIGraphicsGetImageFromCurrentImageContext() else {
            UIGraphicsEndImageContext()
            throw PhotoStripError.contextCreationFailed
        }
        UIGraphicsEndImageContext()

        return result
    }

    // MARK: - Layout Calculations

    private func calculateStripSize(config: PhotoStripConfig, photoCount: Int) -> CGSize {
        let extraHeight: CGFloat = {
            var extra: CGFloat = 0
            if config.logo != nil { extra += config.logoHeight + 10 }
            if config.stampText != nil { extra += config.stampFont.lineHeight + 10 }
            return extra
        }()

        switch config.layout {
        case .vertical:
            let width = config.cellSize.width + config.outerMargin * 2
            let height = CGFloat(photoCount) * config.cellSize.height
                + CGFloat(photoCount - 1) * config.cellPadding
                + config.outerMargin * 2
                + extraHeight
            return CGSize(width: width, height: height)

        case .horizontal:
            let width = CGFloat(photoCount) * config.cellSize.width
                + CGFloat(photoCount - 1) * config.cellPadding
                + config.outerMargin * 2
            let height = config.cellSize.height + config.outerMargin * 2 + extraHeight
            return CGSize(width: width, height: height)

        case .grid(let columns):
            let rows = Int(ceil(Double(photoCount) / Double(columns)))
            let width = CGFloat(columns) * config.cellSize.width
                + CGFloat(columns - 1) * config.cellPadding
                + config.outerMargin * 2
            let height = CGFloat(rows) * config.cellSize.height
                + CGFloat(rows - 1) * config.cellPadding
                + config.outerMargin * 2
                + extraHeight
            return CGSize(width: width, height: height)
        }
    }

    private func calculateCellRects(config: PhotoStripConfig, photoCount: Int, stripSize: CGSize) -> [CGRect] {
        var rects: [CGRect] = []
        rects.reserveCapacity(photoCount)

        switch config.layout {
        case .vertical:
            for i in 0..<photoCount {
                let y = config.outerMargin + CGFloat(i) * (config.cellSize.height + config.cellPadding)
                rects.append(CGRect(
                    x: config.outerMargin,
                    y: y,
                    width: config.cellSize.width,
                    height: config.cellSize.height
                ))
            }

        case .horizontal:
            for i in 0..<photoCount {
                let x = config.outerMargin + CGFloat(i) * (config.cellSize.width + config.cellPadding)
                rects.append(CGRect(
                    x: x,
                    y: config.outerMargin,
                    width: config.cellSize.width,
                    height: config.cellSize.height
                ))
            }

        case .grid(let columns):
            for i in 0..<photoCount {
                let col = i % columns
                let row = i / columns
                let x = config.outerMargin + CGFloat(col) * (config.cellSize.width + config.cellPadding)
                let y = config.outerMargin + CGFloat(row) * (config.cellSize.height + config.cellPadding)
                rects.append(CGRect(
                    x: x,
                    y: y,
                    width: config.cellSize.width,
                    height: config.cellSize.height
                ))
            }
        }

        return rects
    }

    /// Calculate the rect needed to aspect-fill a photo into a cell.
    private func aspectFillRect(for imageSize: CGSize, in cellRect: CGRect) -> CGRect {
        let imageAspect = imageSize.width / imageSize.height
        let cellAspect = cellRect.width / cellRect.height

        var drawRect = cellRect
        if imageAspect > cellAspect {
            // Image is wider: fill height, crop width
            let drawWidth = cellRect.height * imageAspect
            drawRect = CGRect(
                x: cellRect.midX - drawWidth / 2,
                y: cellRect.minY,
                width: drawWidth,
                height: cellRect.height
            )
        } else {
            // Image is taller: fill width, crop height
            let drawHeight = cellRect.width / imageAspect
            drawRect = CGRect(
                x: cellRect.minX,
                y: cellRect.midY - drawHeight / 2,
                width: cellRect.width,
                height: drawHeight
            )
        }

        return drawRect
    }
}

// MARK: - Photo Capture Handler

private final class PhotoCaptureHandler: NSObject, AVCapturePhotoCaptureDelegate {
    let completion: (Result<UIImage, Error>) -> Void

    init(completion: @escaping (Result<UIImage, Error>) -> Void) {
        self.completion = completion
        super.init()
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error = error {
            completion(.failure(error))
            return
        }

        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            completion(.failure(PhotoStripError.photoCaptureFailed))
            return
        }

        completion(.success(image))
    }
}

// MARK: - Errors

public enum PhotoStripError: LocalizedError {
    case cameraUnavailable
    case cannotConfigureSession
    case photoCaptureFailed
    case noPhotos
    case contextCreationFailed
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .cameraUnavailable: return "No camera available."
        case .cannotConfigureSession: return "Cannot configure capture session."
        case .photoCaptureFailed: return "Failed to capture photo."
        case .noPhotos: return "No photos provided for compositing."
        case .contextCreationFailed: return "Failed to create graphics context."
        case .encodingFailed: return "Failed to encode the final strip image."
        }
    }
}
