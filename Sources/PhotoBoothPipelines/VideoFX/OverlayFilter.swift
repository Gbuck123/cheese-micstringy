// OverlayFilter.swift
// Alpha-blends a PNG overlay (static or animated sprite sheet) onto the camera feed.

import Foundation
import Metal
import MetalKit

public final class OverlayFilter: MetalFilter, AnimatableFilter, TextureResourceFilter {

    public let name = "OverlayComposite"
    public var isEnabled: Bool = true

    // MARK: - Configuration

    /// Overall overlay opacity (0..1).
    public var opacity: Float = 1.0

    /// Blend mode: .normal, .multiply, .screen, .overlay
    public enum BlendMode: Int32 {
        case normal   = 0
        case multiply = 1
        case screen   = 2
        case overlay  = 3
    }
    public var blendMode: BlendMode = .normal

    // MARK: Sprite Sheet Configuration

    /// Number of columns in the sprite sheet. 1 for a static overlay.
    public var spriteColumns: Int = 1

    /// Number of rows in the sprite sheet. 1 for a static overlay.
    public var spriteRows: Int = 1

    /// Frames per second for sprite sheet animation.
    public var animationFPS: Double = 12.0

    // MARK: - Internal

    private let pipelineState: MTLComputePipelineState
    private let uniformBuffer: MTLBuffer
    private var overlayTexture: MTLTexture?
    private var currentFrame: Int = 0
    private var animationTime: Double = 0

    struct Uniforms {
        var opacity: Float
        var spriteColumns: Int32
        var spriteRows: Int32
        var currentFrame: Int32
        var blendMode: Int32
        var _pad: SIMD3<Int32> = .zero
    }

    public init(context: MetalContext = .shared) {
        self.pipelineState = context.computePipeline(function: "overlayComposite")
        self.uniformBuffer = context.device.makeBuffer(
            length: MemoryLayout<Uniforms>.stride,
            options: .storageModeShared
        )!
        uniformBuffer.label = "Overlay_Uniforms"
    }

    // MARK: - Overlay Loading

    /// Load a static overlay or sprite sheet from the app bundle.
    public func loadOverlay(named name: String, extension ext: String = "png",
                            bundle: Bundle = .main, context: MetalContext = .shared) {
        let loader = MTKTextureLoader(device: context.device)
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
            .SRGB: true,
            .generateMipmaps: false
        ]

        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            print("[OverlayFilter] Overlay '\(name).\(ext)' not found.")
            return
        }

        do {
            overlayTexture = try loader.newTexture(URL: url, options: options)
            overlayTexture?.label = "Overlay_\(name)"
        } catch {
            print("[OverlayFilter] Failed to load overlay: \(error)")
        }
    }

    /// Load overlay from a CGImage (useful for dynamically generated overlays).
    public func loadOverlay(from cgImage: CGImage, context: MetalContext = .shared) {
        let loader = MTKTextureLoader(device: context.device)
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .SRGB: true
        ]
        do {
            overlayTexture = try loader.newTexture(cgImage: cgImage, options: options)
        } catch {
            print("[OverlayFilter] Failed to create texture from CGImage: \(error)")
        }
    }

    /// Set a pre-existing MTLTexture as the overlay (e.g., from a video decoder).
    public func setOverlayTexture(_ texture: MTLTexture) {
        self.overlayTexture = texture
    }

    // MARK: TextureResourceFilter

    public func setAuxiliaryTextures(_ textures: [String: MTLTexture]) {
        if let overlay = textures["overlay"] {
            self.overlayTexture = overlay
        }
    }

    // MARK: AnimatableFilter

    public func update(time: Double, deltaTime: Double) {
        animationTime += deltaTime
        let totalFrames = spriteColumns * spriteRows
        if totalFrames > 1 {
            currentFrame = Int(animationTime * animationFPS) % totalFrames
        } else {
            currentFrame = 0
        }
    }

    // MARK: MetalFilter

    public func encode(encoder: MTLComputeCommandEncoder, input: MTLTexture, output: MTLTexture) {
        guard let overlay = overlayTexture else { return }

        var uniforms = Uniforms(
            opacity: opacity,
            spriteColumns: Int32(spriteColumns),
            spriteRows: Int32(spriteRows),
            currentFrame: Int32(currentFrame),
            blendMode: blendMode.rawValue
        )
        uniformBuffer.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<Uniforms>.stride)

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(overlay, index: 2)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 0)

        let (grid, group) = pipelineState.threadgroupParameters(for: output)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
    }
}
