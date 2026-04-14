// VintageFilter.swift
// Vintage / film grain effect with animated grain, sepia toning, and lifted blacks.

import Foundation
import Metal

public final class VintageFilter: MetalFilter, AnimatableFilter {

    public let name = "Vintage_FilmGrain"
    public var isEnabled: Bool = true

    // MARK: - Tweakable Parameters

    /// Grain intensity (0 = none, 0.1 = subtle, 0.3 = heavy).
    public var grainIntensity: Float = 0.12

    /// Sepia toning strength (0 = none, 1 = full sepia).
    public var sepiaStrength: Float = 0.4

    /// Vignette amount baked into the vintage look.
    public var vignetteAmount: Float = 0.5

    /// Lifted blacks / fade amount.
    public var fadeAmount: Float = 0.08

    /// Saturation (1 = full, 0 = monochrome).
    public var saturation: Float = 0.7

    // MARK: - Internal

    private let pipelineState: MTLComputePipelineState
    private let uniformBuffer: MTLBuffer
    private var currentTime: Float = 0

    struct Uniforms {
        var time: Float
        var grainIntensity: Float
        var sepiaStrength: Float
        var vignetteAmount: Float
        var fadeAmount: Float
        var saturation: Float
    }

    public init(context: MetalContext = .shared) {
        self.pipelineState = context.computePipeline(function: "vintageFilmGrain")
        self.uniformBuffer = context.device.makeBuffer(
            length: MemoryLayout<Uniforms>.stride,
            options: .storageModeShared
        )!
        uniformBuffer.label = "Vintage_Uniforms"
    }

    // MARK: AnimatableFilter

    public func update(time: Double, deltaTime: Double) {
        currentTime = Float(time)
    }

    // MARK: MetalFilter

    public func encode(encoder: MTLComputeCommandEncoder, input: MTLTexture, output: MTLTexture) {
        var uniforms = Uniforms(
            time: currentTime,
            grainIntensity: grainIntensity,
            sepiaStrength: sepiaStrength,
            vignetteAmount: vignetteAmount,
            fadeAmount: fadeAmount,
            saturation: saturation
        )
        uniformBuffer.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<Uniforms>.stride)

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 0)

        let (grid, group) = pipelineState.threadgroupParameters(for: output)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
    }
}
