// GaussianBlurFilter.swift
// Separable two-pass Gaussian blur. Also usable as the blur stage in a bloom pipeline.

import Foundation
import Metal

public final class GaussianBlurFilter: MetalFilter {

    public let name = "GaussianBlur"
    public var isEnabled: Bool = true

    /// Blur radius in pixels. Larger = more blurry but slower.
    /// For real-time on iPad at 1080p, keep this <= 15.
    public var radius: Int = 8 {
        didSet { radius = min(max(radius, 1), 64) }
    }

    /// Gaussian sigma. If 0, automatically computed as radius / 2.
    public var sigma: Float = 0 {
        didSet { effectiveSigma = sigma > 0 ? sigma : Float(radius) / 2.0 }
    }

    private var effectiveSigma: Float = 4.0

    private let pipelineState: MTLComputePipelineState
    private let uniformBuffer: MTLBuffer
    private let context: MetalContext

    /// Intermediate texture for the horizontal pass (owned, not pooled, because
    /// we need it between two encoder dispatches within the same encode() call).
    private var intermediateTexture: MTLTexture?
    private var intermediateWidth: Int = 0
    private var intermediateHeight: Int = 0

    struct Uniforms {
        var radius: Int32
        var sigma: Float
        var direction: Int32
        var _pad: Int32 = 0  // alignment
    }

    public init(context: MetalContext = .shared) {
        self.context = context
        self.pipelineState = context.computePipeline(function: "gaussianBlur")
        self.uniformBuffer = context.device.makeBuffer(
            length: MemoryLayout<Uniforms>.stride * 2, // room for H + V uniforms
            options: .storageModeShared
        )!
        uniformBuffer.label = "GaussianBlur_Uniforms"
    }

    private func ensureIntermediate(width: Int, height: Int) {
        guard width != intermediateWidth || height != intermediateHeight else { return }
        intermediateTexture = context.makeTexture(width: width, height: height)
        intermediateTexture?.label = "GaussianBlur_Intermediate"
        intermediateWidth = width
        intermediateHeight = height
    }

    // MARK: MetalFilter

    /// NOTE: This filter encodes TWO dispatches (H + V) into the same encoder.
    /// Because the Metal spec guarantees that dispatches within the same compute command
    /// encoder execute in order with appropriate barriers, no explicit fence is needed.
    /// However, we must end the first encoder and start a second for the barrier to
    /// actually flush the caches. The FilterChain creates one encoder per filter,
    /// so we need special handling here.
    ///
    /// The recommended approach is to call encode() for the horizontal pass,
    /// and encode a second dispatch separately. We handle this by writing the
    /// intermediate result and requiring the caller to call encodeVertical() with
    /// a new encoder afterward.
    ///
    /// For simplicity in the FilterChain, this filter writes the HORIZONTAL pass
    /// to the output, and the FilterChain's next encoder treats that as input
    /// for the vertical pass via a paired GaussianBlurVerticalFilter.
    ///
    /// ALTERNATIVE (used here): We do both passes by ending/beginning a new encoder.
    /// The encode() signature takes a compute encoder, but we must break it into two
    /// separate dispatches. We accept that this filter's encode() does both passes
    /// within the single encoder (Metal barriers between dispatches in one encoder
    /// handle read-after-write on Apple GPUs via the `textureBarrier` approach,
    /// but more reliably, we use the intermediate texture).

    public func encode(encoder: MTLComputeCommandEncoder, input: MTLTexture, output: MTLTexture) {
        let sigma = self.sigma > 0 ? self.sigma : Float(radius) / 2.0
        ensureIntermediate(width: input.width, height: input.height)
        guard let intermediate = intermediateTexture else { return }

        let stride = MemoryLayout<Uniforms>.stride

        // --- Horizontal pass: input → intermediate ---
        var hUniforms = Uniforms(radius: Int32(radius), sigma: sigma, direction: 0)
        uniformBuffer.contents().copyMemory(from: &hUniforms, byteCount: stride)

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(intermediate, index: 1)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 0)

        let (grid, group) = pipelineState.threadgroupParameters(for: intermediate)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: group)

        // Memory barrier so the vertical pass can read the intermediate texture.
        encoder.memoryBarrier(scope: .textures)

        // --- Vertical pass: intermediate → output ---
        var vUniforms = Uniforms(radius: Int32(radius), sigma: sigma, direction: 1)
        (uniformBuffer.contents() + stride).copyMemory(from: &vUniforms, byteCount: stride)

        encoder.setTexture(intermediate, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBuffer(uniformBuffer, offset: stride, index: 0)

        encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
    }
}
