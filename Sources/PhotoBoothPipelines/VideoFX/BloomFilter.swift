// BloomFilter.swift
// Multi-pass glow/bloom effect: threshold → downsample → blur → combine.
// This is a composite filter that manages its own sub-passes.

import Foundation
import Metal

public final class BloomFilter: MetalFilter, AnimatableFilter {

    public let name = "Bloom"
    public var isEnabled: Bool = true

    /// Luminance threshold. Pixels below this don't contribute to bloom.
    public var threshold: Float = 0.65

    /// Soft knee for a smooth threshold transition.
    public var softKnee: Float = 0.5

    /// Bloom intensity when combined with the original.
    public var intensity: Float = 0.8

    /// Blur radius for the bloom pass.
    public var blurRadius: Int = 10

    private let thresholdPipeline: MTLComputePipelineState
    private let combinePipeline: MTLComputePipelineState
    private let blurPipeline: MTLComputePipelineState

    private let thresholdUniformBuffer: MTLBuffer
    private let combineUniformBuffer: MTLBuffer
    private let blurUniformBufferH: MTLBuffer
    private let blurUniformBufferV: MTLBuffer

    private let context: MetalContext

    // Intermediate textures for the bloom pipeline (allocated lazily, resized as needed).
    private var brightPassTex: MTLTexture?
    private var blurIntermediateTex: MTLTexture?
    private var bloomBlurredTex: MTLTexture?
    private var cachedWidth: Int = 0
    private var cachedHeight: Int = 0

    struct ThresholdUniforms {
        var threshold: Float
        var softKnee: Float
    }

    struct CombineUniforms {
        var intensity: Float
    }

    struct BlurUniforms {
        var radius: Int32
        var sigma: Float
        var direction: Int32
        var _pad: Int32 = 0
    }

    public init(context: MetalContext = .shared) {
        self.context = context
        self.thresholdPipeline = context.computePipeline(function: "bloomThreshold")
        self.combinePipeline = context.computePipeline(function: "bloomCombine")
        self.blurPipeline = context.computePipeline(function: "gaussianBlur")

        let device = context.device
        self.thresholdUniformBuffer = device.makeBuffer(length: MemoryLayout<ThresholdUniforms>.stride, options: .storageModeShared)!
        self.combineUniformBuffer = device.makeBuffer(length: MemoryLayout<CombineUniforms>.stride, options: .storageModeShared)!
        self.blurUniformBufferH = device.makeBuffer(length: MemoryLayout<BlurUniforms>.stride, options: .storageModeShared)!
        self.blurUniformBufferV = device.makeBuffer(length: MemoryLayout<BlurUniforms>.stride, options: .storageModeShared)!
    }

    // MARK: AnimatableFilter

    public func update(time: Double, deltaTime: Double) {
        // Bloom can optionally pulse intensity with time — leave as no-op for static bloom.
    }

    // MARK: Texture Management

    private func ensureTextures(width: Int, height: Int) {
        // Work at half resolution for performance.
        let bw = width / 2
        let bh = height / 2

        guard bw != cachedWidth || bh != cachedHeight else { return }
        cachedWidth = bw
        cachedHeight = bh

        brightPassTex = context.makeTexture(width: bw, height: bh)
        brightPassTex?.label = "Bloom_BrightPass"

        blurIntermediateTex = context.makeTexture(width: bw, height: bh)
        blurIntermediateTex?.label = "Bloom_BlurIntermediate"

        bloomBlurredTex = context.makeTexture(width: bw, height: bh)
        bloomBlurredTex?.label = "Bloom_Blurred"
    }

    // MARK: MetalFilter

    public func encode(encoder: MTLComputeCommandEncoder, input: MTLTexture, output: MTLTexture) {
        ensureTextures(width: input.width, height: input.height)

        guard let brightTex = brightPassTex,
              let blurMid = blurIntermediateTex,
              let blurred = bloomBlurredTex else { return }

        let sigma = Float(blurRadius) / 2.0

        // --- Pass 1: Brightness threshold (input → brightTex at half res) ---
        var threshUni = ThresholdUniforms(threshold: threshold, softKnee: softKnee)
        thresholdUniformBuffer.contents().copyMemory(from: &threshUni, byteCount: MemoryLayout<ThresholdUniforms>.stride)

        encoder.setComputePipelineState(thresholdPipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(brightTex, index: 1)
        encoder.setBuffer(thresholdUniformBuffer, offset: 0, index: 0)

        let (grid1, group1) = thresholdPipeline.threadgroupParameters(for: brightTex)
        encoder.dispatchThreads(grid1, threadsPerThreadgroup: group1)
        encoder.memoryBarrier(scope: .textures)

        // --- Pass 2a: Horizontal blur (brightTex → blurMid) ---
        var hBlur = BlurUniforms(radius: Int32(blurRadius), sigma: sigma, direction: 0)
        blurUniformBufferH.contents().copyMemory(from: &hBlur, byteCount: MemoryLayout<BlurUniforms>.stride)

        encoder.setComputePipelineState(blurPipeline)
        encoder.setTexture(brightTex, index: 0)
        encoder.setTexture(blurMid, index: 1)
        encoder.setBuffer(blurUniformBufferH, offset: 0, index: 0)

        let (grid2, group2) = blurPipeline.threadgroupParameters(for: blurMid)
        encoder.dispatchThreads(grid2, threadsPerThreadgroup: group2)
        encoder.memoryBarrier(scope: .textures)

        // --- Pass 2b: Vertical blur (blurMid → blurred) ---
        var vBlur = BlurUniforms(radius: Int32(blurRadius), sigma: sigma, direction: 1)
        blurUniformBufferV.contents().copyMemory(from: &vBlur, byteCount: MemoryLayout<BlurUniforms>.stride)

        encoder.setTexture(blurMid, index: 0)
        encoder.setTexture(blurred, index: 1)
        encoder.setBuffer(blurUniformBufferV, offset: 0, index: 0)

        encoder.dispatchThreads(grid2, threadsPerThreadgroup: group2)
        encoder.memoryBarrier(scope: .textures)

        // --- Pass 3: Combine original + blurred bloom → output ---
        var combineUni = CombineUniforms(intensity: intensity)
        combineUniformBuffer.contents().copyMemory(from: &combineUni, byteCount: MemoryLayout<CombineUniforms>.stride)

        encoder.setComputePipelineState(combinePipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(blurred, index: 2)
        encoder.setBuffer(combineUniformBuffer, offset: 0, index: 0)

        let (grid3, group3) = combinePipeline.threadgroupParameters(for: output)
        encoder.dispatchThreads(grid3, threadsPerThreadgroup: group3)
    }
}
