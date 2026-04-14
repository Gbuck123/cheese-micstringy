// ColorGradeFilter.swift
// Applies a 3D LUT loaded from a PNG strip image for cinematic color grading.

import Foundation
import Metal
import MetalKit

public final class ColorGradeFilter: MetalFilter, TextureResourceFilter {

    public let name = "ColorGrade_LUT"
    public var isEnabled: Bool = true

    /// Blend intensity: 0 = original, 1 = fully graded.
    public var intensity: Float = 1.0

    private let pipelineState: MTLComputePipelineState
    private var lutTexture: MTLTexture?

    // Uniform buffer (tiny — allocated once, updated in-place each frame).
    private let uniformBuffer: MTLBuffer

    struct Uniforms {
        var intensity: Float
    }

    public init(context: MetalContext = .shared) {
        self.pipelineState = context.computePipeline(function: "colorGradeLUT")
        self.uniformBuffer = context.device.makeBuffer(
            length: MemoryLayout<Uniforms>.stride,
            options: .storageModeShared
        )!
        uniformBuffer.label = "ColorGrade_Uniforms"
    }

    // MARK: - LUT Loading

    /// Load a LUT from a PNG file in the app bundle.
    /// The image should be a horizontal strip: e.g., 1024x32 for a 32^3 LUT.
    public func loadLUT(named name: String, bundle: Bundle = .main, context: MetalContext = .shared) {
        let loader = MTKTextureLoader(device: context.device)
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
            .SRGB: false  // LUTs must be loaded as linear
        ]

        guard let url = bundle.url(forResource: name, withExtension: "png") else {
            print("[ColorGradeFilter] LUT '\(name).png' not found in bundle.")
            return
        }

        do {
            lutTexture = try loader.newTexture(URL: url, options: options)
            lutTexture?.label = "LUT_\(name)"
        } catch {
            print("[ColorGradeFilter] Failed to load LUT: \(error)")
        }
    }

    /// Load a LUT from raw data (e.g., downloaded from server).
    public func loadLUT(from data: Data, context: MetalContext = .shared) {
        let loader = MTKTextureLoader(device: context.device)
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .SRGB: false
        ]

        do {
            lutTexture = try loader.newTexture(data: data, options: options)
        } catch {
            print("[ColorGradeFilter] Failed to load LUT from data: \(error)")
        }
    }

    // MARK: TextureResourceFilter

    public func setAuxiliaryTextures(_ textures: [String: MTLTexture]) {
        if let lut = textures["lut"] {
            self.lutTexture = lut
        }
    }

    // MARK: MetalFilter

    public func encode(encoder: MTLComputeCommandEncoder, input: MTLTexture, output: MTLTexture) {
        guard let lut = lutTexture else {
            // No LUT loaded — passthrough by reading input and writing to output.
            // In practice the chain should skip disabled filters, but defensively handle it.
            return
        }

        var uniforms = Uniforms(intensity: intensity)
        uniformBuffer.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<Uniforms>.stride)

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(lut, index: 2)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 0)

        let (grid, group) = pipelineState.threadgroupParameters(for: output)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
    }
}
