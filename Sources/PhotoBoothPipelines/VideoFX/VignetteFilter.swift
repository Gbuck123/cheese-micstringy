// VignetteFilter.swift
// Configurable vignette with color, roundness, and softness controls.

import Foundation
import Metal
import simd

public final class VignetteFilter: MetalFilter {

    public let name = "Vignette"
    public var isEnabled: Bool = true

    /// Overall strength (0 = none, 1 = full vignette).
    public var intensity: Float = 0.7

    /// Inner radius where falloff begins (0..1 in normalised coordinates).
    public var radius: Float = 0.4

    /// Width of the falloff region.
    public var softness: Float = 0.5

    /// Roundness: 1.0 = perfectly circular; lower values create a wider oval.
    public var roundness: Float = 1.0

    /// Vignette colour (default: black).
    public var color: SIMD3<Float> = SIMD3<Float>(0, 0, 0)

    private let pipelineState: MTLComputePipelineState
    private let uniformBuffer: MTLBuffer

    struct Uniforms {
        var intensity: Float
        var radius: Float
        var softness: Float
        var roundness: Float
        var color: SIMD3<Float>
        var _pad: Float = 0
    }

    public init(context: MetalContext = .shared) {
        self.pipelineState = context.computePipeline(function: "vignette")
        self.uniformBuffer = context.device.makeBuffer(
            length: MemoryLayout<Uniforms>.stride,
            options: .storageModeShared
        )!
        uniformBuffer.label = "Vignette_Uniforms"
    }

    public func encode(encoder: MTLComputeCommandEncoder, input: MTLTexture, output: MTLTexture) {
        var uniforms = Uniforms(
            intensity: intensity,
            radius: radius,
            softness: softness,
            roundness: roundness,
            color: color
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
