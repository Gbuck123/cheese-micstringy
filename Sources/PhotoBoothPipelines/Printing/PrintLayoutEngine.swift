// PrintLayoutEngine.swift
// Composites photos onto standard print templates at 300 DPI.
// Supports 4x6 single, 2x6 strip (2-up on 4x6), and custom layouts.

import UIKit
import CoreGraphics

// MARK: - Layout Definitions

/// Represents a physical print size in inches.
public struct PrintSize: Equatable, Sendable {
    public let widthInches: CGFloat
    public let heightInches: CGFloat

    public static let fourBySix = PrintSize(widthInches: 4, heightInches: 6)
    public static let twoBySix = PrintSize(widthInches: 2, heightInches: 6)
    public static let fiveBySeven = PrintSize(widthInches: 5, heightInches: 7)
    public static let eightByTen = PrintSize(widthInches: 8, heightInches: 10)

    public func pixelSize(dpi: CGFloat = 300) -> CGSize {
        CGSize(width: widthInches * dpi, height: heightInches * dpi)
    }
}

/// Describes how a single photo is placed within a layout.
public struct PhotoSlot {
    /// Frame in points (at target DPI) within the layout canvas.
    public let frame: CGRect
    /// Corner radius in points for rounded-corner masks. 0 = sharp corners.
    public let cornerRadius: CGFloat
    /// Border width in points. 0 = no border.
    public let borderWidth: CGFloat
    public let borderColor: UIColor

    public init(frame: CGRect,
                cornerRadius: CGFloat = 0,
                borderWidth: CGFloat = 0,
                borderColor: UIColor = .white) {
        self.frame = frame
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
        self.borderColor = borderColor
    }
}

/// A complete print layout with background, photo slots, overlays, and crop marks.
public struct PrintLayout {
    public let canvasSize: CGSize          // In pixels at target DPI
    public let dpi: CGFloat
    public let backgroundColor: UIColor
    public let backgroundImage: UIImage?   // Optional branded background
    public let slots: [PhotoSlot]
    public let overlayImage: UIImage?      // Optional overlay (logo, frame, watermark)
    public let includeCropMarks: Bool
    public let cropMarkInset: CGFloat      // Distance from edge for crop marks

    public init(canvasSize: CGSize,
                dpi: CGFloat = 300,
                backgroundColor: UIColor = .white,
                backgroundImage: UIImage? = nil,
                slots: [PhotoSlot],
                overlayImage: UIImage? = nil,
                includeCropMarks: Bool = false,
                cropMarkInset: CGFloat = 0) {
        self.canvasSize = canvasSize
        self.dpi = dpi
        self.backgroundColor = backgroundColor
        self.backgroundImage = backgroundImage
        self.slots = slots
        self.overlayImage = overlayImage
        self.includeCropMarks = includeCropMarks
        self.cropMarkInset = cropMarkInset
    }
}

// MARK: - Preset Layouts

public enum PrintLayoutPreset {

    /// Single photo filling a 4x6 print with small margins.
    public static func singleFourBySix(dpi: CGFloat = 300,
                                       marginInches: CGFloat = 0.0) -> PrintLayout {
        let canvas = PrintSize.fourBySix.pixelSize(dpi: dpi)
        let margin = marginInches * dpi
        let photoFrame = CGRect(
            x: margin,
            y: margin,
            width: canvas.width - margin * 2,
            height: canvas.height - margin * 2
        )
        return PrintLayout(
            canvasSize: canvas,
            dpi: dpi,
            slots: [PhotoSlot(frame: photoFrame)]
        )
    }

    /// 2x6 photo strip: 4 photos stacked vertically with spacing.
    /// Returns a layout for a single 2x6 strip.
    public static func photoStrip2x6(dpi: CGFloat = 300,
                                     photoCount: Int = 4,
                                     spacingInches: CGFloat = 0.08,
                                     marginInches: CGFloat = 0.1,
                                     cornerRadius: CGFloat = 0) -> PrintLayout {
        let canvas = PrintSize.twoBySix.pixelSize(dpi: dpi)
        let margin = marginInches * dpi
        let spacing = spacingInches * dpi

        let availableHeight = canvas.height - margin * 2 - spacing * CGFloat(photoCount - 1)
        let photoHeight = availableHeight / CGFloat(photoCount)
        let photoWidth = canvas.width - margin * 2

        var slots: [PhotoSlot] = []
        for i in 0..<photoCount {
            let y = margin + CGFloat(i) * (photoHeight + spacing)
            slots.append(PhotoSlot(
                frame: CGRect(x: margin, y: y, width: photoWidth, height: photoHeight),
                cornerRadius: cornerRadius
            ))
        }

        return PrintLayout(
            canvasSize: canvas,
            dpi: dpi,
            slots: slots
        )
    }

    /// Two 2x6 strips side-by-side on a single 4x6 sheet with cut line.
    /// This is the standard "2-up strip" layout that most photo booths use.
    public static func doubleStrip4x6(dpi: CGFloat = 300,
                                      photoCount: Int = 4,
                                      spacingInches: CGFloat = 0.08,
                                      marginInches: CGFloat = 0.1,
                                      gutterInches: CGFloat = 0.05,
                                      cornerRadius: CGFloat = 0) -> PrintLayout {
        let canvas = PrintSize.fourBySix.pixelSize(dpi: dpi)
        let margin = marginInches * dpi
        let spacing = spacingInches * dpi
        let gutter = gutterInches * dpi

        let stripWidth = (canvas.width - margin * 2 - gutter) / 2.0
        let availableHeight = canvas.height - margin * 2 - spacing * CGFloat(photoCount - 1)
        let photoHeight = availableHeight / CGFloat(photoCount)

        var slots: [PhotoSlot] = []

        // Left strip
        for i in 0..<photoCount {
            let y = margin + CGFloat(i) * (photoHeight + spacing)
            slots.append(PhotoSlot(
                frame: CGRect(x: margin, y: y, width: stripWidth, height: photoHeight),
                cornerRadius: cornerRadius
            ))
        }

        // Right strip (duplicate)
        for i in 0..<photoCount {
            let y = margin + CGFloat(i) * (photoHeight + spacing)
            slots.append(PhotoSlot(
                frame: CGRect(x: margin + stripWidth + gutter, y: y,
                              width: stripWidth, height: photoHeight),
                cornerRadius: cornerRadius
            ))
        }

        return PrintLayout(
            canvasSize: canvas,
            dpi: dpi,
            slots: slots,
            includeCropMarks: true,
            cropMarkInset: margin + stripWidth + gutter / 2
        )
    }

    /// Three photos + logo/text area on a 4x6.
    public static func threeUpWithBranding(dpi: CGFloat = 300,
                                           brandingHeight: CGFloat = 1.2) -> PrintLayout {
        let canvas = PrintSize.fourBySix.pixelSize(dpi: dpi)
        let margin: CGFloat = 0.15 * dpi
        let spacing: CGFloat = 0.08 * dpi
        let brandingPx = brandingHeight * dpi

        let photoAreaHeight = canvas.height - margin * 2 - brandingPx - spacing * 3
        let photoHeight = photoAreaHeight / 3.0
        let photoWidth = canvas.width - margin * 2

        var slots: [PhotoSlot] = []
        for i in 0..<3 {
            let y = margin + CGFloat(i) * (photoHeight + spacing)
            slots.append(PhotoSlot(
                frame: CGRect(x: margin, y: y, width: photoWidth, height: photoHeight),
                cornerRadius: 8
            ))
        }

        return PrintLayout(
            canvasSize: canvas,
            dpi: dpi,
            slots: slots
        )
    }
}

// MARK: - Print Layout Engine

public final class PrintLayoutEngine {

    public init() {}

    // MARK: - Main Compositing

    /// Composites an array of photos into the given layout, returning a print-ready UIImage.
    ///
    /// - Parameters:
    ///   - photos: The source photos. For double-strip layouts, photos are duplicated across strips.
    ///   - layout: The PrintLayout defining canvas size, slots, and options.
    ///   - fillMode: How photos are scaled into their slots.
    /// - Returns: A print-ready UIImage at the layout's target DPI.
    public func composite(photos: [UIImage],
                          layout: PrintLayout,
                          fillMode: PhotoFillMode = .aspectFill) -> UIImage? {

        let renderer = UIGraphicsImageRenderer(size: layout.canvasSize)

        return renderer.image { ctx in
            let cgContext = ctx.cgContext

            // 1. Draw background
            layout.backgroundColor.setFill()
            cgContext.fill(CGRect(origin: .zero, size: layout.canvasSize))

            if let bg = layout.backgroundImage {
                bg.draw(in: CGRect(origin: .zero, size: layout.canvasSize))
            }

            // 2. Draw photos into slots
            for (index, slot) in layout.slots.enumerated() {
                // For double-strip: reuse photos (slot index wraps around photo count)
                let photoIndex = index % max(photos.count, 1)
                guard photoIndex < photos.count else { continue }
                let photo = photos[photoIndex]

                drawPhoto(photo, in: slot, context: cgContext, fillMode: fillMode)
            }

            // 3. Draw overlay
            if let overlay = layout.overlayImage {
                overlay.draw(in: CGRect(origin: .zero, size: layout.canvasSize))
            }

            // 4. Draw crop marks / cut lines
            if layout.includeCropMarks {
                drawCropMarks(in: layout, context: cgContext)
            }
        }
    }

    /// Generates a print-ready image with embedded DPI metadata for precise printing.
    public func compositePrintReady(photos: [UIImage],
                                    layout: PrintLayout,
                                    fillMode: PhotoFillMode = .aspectFill) -> (image: UIImage, data: Data)? {
        guard let composited = composite(photos: photos, layout: layout, fillMode: fillMode) else {
            return nil
        }

        // Embed DPI metadata in TIFF/JPEG output
        guard let cgImage = composited.cgImage else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            "public.jpeg" as CFString,  // JPEG for smaller files, use "public.tiff" for lossless
            1,
            nil
        ) else { return nil }

        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: layout.dpi,
            kCGImagePropertyDPIHeight: layout.dpi,
            kCGImageDestinationLossyCompressionQuality: 0.95
        ]

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        CGImageDestinationFinalize(destination)

        let imageData = data as Data
        let finalImage = UIImage(data: imageData) ?? composited
        return (finalImage, imageData)
    }

    // MARK: - Photo Drawing

    public enum PhotoFillMode {
        case aspectFill   // Crop to fill (most common for photo booths)
        case aspectFit    // Letterbox to fit
        case stretch      // Distort to fill
    }

    private func drawPhoto(_ photo: UIImage,
                           in slot: PhotoSlot,
                           context: CGContext,
                           fillMode: PhotoFillMode) {
        context.saveGState()

        // Apply corner radius clipping
        if slot.cornerRadius > 0 {
            let clipPath = UIBezierPath(roundedRect: slot.frame, cornerRadius: slot.cornerRadius)
            clipPath.addClip()
        } else {
            context.clip(to: slot.frame)
        }

        // Calculate draw rect based on fill mode
        let drawRect: CGRect
        switch fillMode {
        case .aspectFill:
            drawRect = aspectFillRect(for: photo.size, in: slot.frame)
        case .aspectFit:
            drawRect = aspectFitRect(for: photo.size, in: slot.frame)
        case .stretch:
            drawRect = slot.frame
        }

        photo.draw(in: drawRect)

        context.restoreGState()

        // Draw border on top
        if slot.borderWidth > 0 {
            context.saveGState()
            slot.borderColor.setStroke()
            let borderRect = slot.frame.insetBy(dx: slot.borderWidth / 2, dy: slot.borderWidth / 2)
            if slot.cornerRadius > 0 {
                let borderPath = UIBezierPath(roundedRect: borderRect, cornerRadius: slot.cornerRadius)
                borderPath.lineWidth = slot.borderWidth
                borderPath.stroke()
            } else {
                context.setLineWidth(slot.borderWidth)
                context.stroke(borderRect)
            }
            context.restoreGState()
        }
    }

    private func aspectFillRect(for imageSize: CGSize, in targetRect: CGRect) -> CGRect {
        let widthRatio = targetRect.width / imageSize.width
        let heightRatio = targetRect.height / imageSize.height
        let scale = max(widthRatio, heightRatio)

        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale

        return CGRect(
            x: targetRect.midX - scaledWidth / 2,
            y: targetRect.midY - scaledHeight / 2,
            width: scaledWidth,
            height: scaledHeight
        )
    }

    private func aspectFitRect(for imageSize: CGSize, in targetRect: CGRect) -> CGRect {
        let widthRatio = targetRect.width / imageSize.width
        let heightRatio = targetRect.height / imageSize.height
        let scale = min(widthRatio, heightRatio)

        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale

        return CGRect(
            x: targetRect.midX - scaledWidth / 2,
            y: targetRect.midY - scaledHeight / 2,
            width: scaledWidth,
            height: scaledHeight
        )
    }

    // MARK: - Crop Marks & Cut Lines

    private func drawCropMarks(in layout: PrintLayout, context: CGContext) {
        context.saveGState()

        let markLength: CGFloat = 20
        let markWidth: CGFloat = 0.5

        // Dashed cut line down the center (for 2-up strips)
        context.setStrokeColor(UIColor.black.cgColor)
        context.setLineWidth(markWidth)
        context.setLineDash(phase: 0, lengths: [6, 4])

        let centerX = layout.cropMarkInset
        if centerX > 0 && centerX < layout.canvasSize.width {
            context.move(to: CGPoint(x: centerX, y: 0))
            context.addLine(to: CGPoint(x: centerX, y: layout.canvasSize.height))
            context.strokePath()
        }

        // Corner crop marks (solid)
        context.setLineDash(phase: 0, lengths: [])
        context.setStrokeColor(UIColor.black.cgColor)
        context.setLineWidth(1.0)

        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            // Top-left
            (CGPoint(x: 0, y: markLength), CGPoint(x: 0, y: 0), CGPoint(x: markLength, y: 0)),
            // Top-right
            (CGPoint(x: layout.canvasSize.width - markLength, y: 0),
             CGPoint(x: layout.canvasSize.width, y: 0),
             CGPoint(x: layout.canvasSize.width, y: markLength)),
            // Bottom-left
            (CGPoint(x: 0, y: layout.canvasSize.height - markLength),
             CGPoint(x: 0, y: layout.canvasSize.height),
             CGPoint(x: markLength, y: layout.canvasSize.height)),
            // Bottom-right
            (CGPoint(x: layout.canvasSize.width, y: layout.canvasSize.height - markLength),
             CGPoint(x: layout.canvasSize.width, y: layout.canvasSize.height),
             CGPoint(x: layout.canvasSize.width - markLength, y: layout.canvasSize.height))
        ]

        for (start, corner, end) in corners {
            context.move(to: start)
            context.addLine(to: corner)
            context.addLine(to: end)
            context.strokePath()
        }

        context.restoreGState()
    }

    // MARK: - DPI Scaling Utility

    /// Scales a camera-captured image to the exact pixel dimensions needed for a target
    /// print size at a given DPI. Camera images are typically much larger than needed.
    ///
    /// For example, an iPad Pro 12MP camera produces ~4032x3024 images.
    /// A 4x6 at 300 DPI only needs 1200x1800 pixels.
    public static func scaleForPrint(_ image: UIImage,
                                     printSize: PrintSize,
                                     dpi: CGFloat = 300,
                                     fillMode: PhotoFillMode = .aspectFill) -> UIImage? {
        let targetPixels = printSize.pixelSize(dpi: dpi)

        let renderer = UIGraphicsImageRenderer(size: targetPixels)
        return renderer.image { _ in
            let drawRect: CGRect
            let targetRect = CGRect(origin: .zero, size: targetPixels)

            switch fillMode {
            case .aspectFill:
                let widthRatio = targetPixels.width / image.size.width
                let heightRatio = targetPixels.height / image.size.height
                let scale = max(widthRatio, heightRatio)
                let scaledSize = CGSize(width: image.size.width * scale,
                                        height: image.size.height * scale)
                drawRect = CGRect(
                    x: (targetPixels.width - scaledSize.width) / 2,
                    y: (targetPixels.height - scaledSize.height) / 2,
                    width: scaledSize.width,
                    height: scaledSize.height
                )
            case .aspectFit:
                let widthRatio = targetPixels.width / image.size.width
                let heightRatio = targetPixels.height / image.size.height
                let scale = min(widthRatio, heightRatio)
                let scaledSize = CGSize(width: image.size.width * scale,
                                        height: image.size.height * scale)
                drawRect = CGRect(
                    x: (targetPixels.width - scaledSize.width) / 2,
                    y: (targetPixels.height - scaledSize.height) / 2,
                    width: scaledSize.width,
                    height: scaledSize.height
                )
            case .stretch:
                drawRect = targetRect
            }

            image.draw(in: drawRect)
        }
    }

    // MARK: - Text Rendering for Branding

    /// Renders text onto a composited image (event name, date, hashtag, etc.).
    public func addText(to image: UIImage,
                        text: String,
                        font: UIFont,
                        color: UIColor,
                        position: CGRect,
                        alignment: NSTextAlignment = .center) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in
            image.draw(at: .zero)

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = alignment

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle
            ]

            (text as NSString).draw(in: position, withAttributes: attributes)
        }
    }
}
