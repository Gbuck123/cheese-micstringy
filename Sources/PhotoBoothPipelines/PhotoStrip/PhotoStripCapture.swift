// PhotoStripCapture.swift
// Captures a sequence of photos (e.g., 4 frames) with effects applied, then
// composites them into a photo strip layout using Metal.

import Foundation
import Metal
import MetalKit
import CoreImage
import UIKit

/// Captures multiple still frames from the camera pipeline and composites them
/// into a classic photo strip layout.
public final class PhotoStripCapture {

    // MARK: - Configuration

    public struct Layout {
        /// Number of photos in the strip.
        public var photoCount: Int = 4

        /// Spacing between photos (in pixels at output resolution).
        public var spacing: Int = 20

        /// Border width around the entire strip.
        public var border: Int = 40

        /// Background colour (RGBA).
        public var backgroundColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1) // white

        /// Output resolution per photo cell.
        public var cellWidth: Int = 600
        public var cellHeight: Int = 400

        /// Total strip dimensions (computed).
        public var totalWidth: Int {
            cellWidth + border * 2
        }
        public var totalHeight: Int {
            (cellHeight * photoCount) + (spacing * (photoCount - 1)) + (border * 2)
        }

        public init() {}
    }

    public var layout = Layout()

    private let context: MetalContext
    private let scaleKernel: MPSScaleFilter
    private var capturedTextures: [MTLTexture] = []

    public init(context: MetalContext = .shared) {
        self.context = context
        self.scaleKernel = MPSScaleFilter(context: context)
    }

    // MARK: - Capture

    /// Add a captured frame (already processed through the filter chain) to the strip.
    /// Returns `true` when all frames have been captured.
    @discardableResult
    public func addFrame(_ texture: MTLTexture) -> Bool {
        // Scale the texture to the cell size.
        let cellTex = context.makeTexture(
            width: layout.cellWidth,
            height: layout.cellHeight,
            usage: [.shaderRead, .shaderWrite, .renderTarget]
        )

        let cmdBuf = context.makeCommandBuffer(label: "PhotoStrip_Scale")
        scaleKernel.encode(commandBuffer: cmdBuf, input: texture, output: cellTex)
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        capturedTextures.append(cellTex)
        return capturedTextures.count >= layout.photoCount
    }

    /// Reset for a new capture session.
    public func reset() {
        capturedTextures.removeAll()
    }

    // MARK: - Compositing

    /// Composite all captured frames into a single photo strip texture.
    /// Returns nil if not enough frames have been captured.
    public func compositeStrip() -> MTLTexture? {
        guard capturedTextures.count >= layout.photoCount else { return nil }

        let stripWidth = layout.totalWidth
        let stripHeight = layout.totalHeight

        // Create the output texture with renderTarget usage for blitting.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: stripWidth,
            height: stripHeight,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .shared // Needs CPU access for saving to disk.

        guard let stripTexture = context.device.makeTexture(descriptor: desc) else { return nil }
        stripTexture.label = "PhotoStrip_Output"

        // Fill with background colour (using a compute shader or CPU fill).
        fillTexture(stripTexture, color: layout.backgroundColor)

        // Blit each captured photo into its position.
        let cmdBuf = context.makeCommandBuffer(label: "PhotoStrip_Composite")
        guard let blit = cmdBuf.makeBlitCommandEncoder() else { return nil }

        for (index, cellTex) in capturedTextures.prefix(layout.photoCount).enumerated() {
            let yOffset = layout.border + index * (layout.cellHeight + layout.spacing)
            let xOffset = layout.border

            let size = MTLSize(
                width: min(cellTex.width, layout.cellWidth),
                height: min(cellTex.height, layout.cellHeight),
                depth: 1
            )

            blit.copy(
                from: cellTex,
                sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: size,
                to: stripTexture,
                destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: xOffset, y: yOffset, z: 0)
            )
        }

        blit.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        return stripTexture
    }

    /// Save the composited strip to the Photos library or as a file.
    public func saveStrip(_ texture: MTLTexture) -> UIImage? {
        let ciImage = CIImage(mtlTexture: texture, options: nil)!
        let cgImage = context.ciContext.createCGImage(ciImage, from: ciImage.extent)
        guard let cg = cgImage else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - Helpers

    private func fillTexture(_ texture: MTLTexture, color: SIMD4<Float>) {
        // For a .shared storage mode texture, we can fill from CPU.
        let bytesPerPixel = 4
        let bytesPerRow = texture.width * bytesPerPixel
        let totalBytes = bytesPerRow * texture.height

        var pixels = [UInt8](repeating: 0, count: totalBytes)
        let r = UInt8(min(max(color.x, 0), 1) * 255)
        let g = UInt8(min(max(color.y, 0), 1) * 255)
        let b = UInt8(min(max(color.z, 0), 1) * 255)
        let a = UInt8(min(max(color.w, 0), 1) * 255)

        for i in stride(from: 0, to: totalBytes, by: 4) {
            pixels[i + 0] = b  // BGRA
            pixels[i + 1] = g
            pixels[i + 2] = r
            pixels[i + 3] = a
        }

        texture.replace(
            region: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: bytesPerRow
        )
    }
}
