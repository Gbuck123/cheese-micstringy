// MPSAccelerators.swift
// Metal Performance Shaders (MPS) wrappers for optimised image operations.
// MPS kernels use Apple's hand-tuned GPU implementations and are typically
// 2-5x faster than equivalent hand-written compute shaders.

import Foundation
import Metal
import MetalPerformanceShaders

// MARK: - MPS Gaussian Blur (Drop-In Replacement)

/// Uses MPSImageGaussianBlur for hardware-optimised Gaussian blur.
/// This is significantly faster than a hand-written separable blur kernel,
/// especially at large radii, because MPS uses optimised tile memory access patterns.
public final class MPSGaussianBlurFilter: MetalFilter {

    public let name = "MPS_GaussianBlur"
    public var isEnabled: Bool = true

    /// Blur sigma. MPS requires an odd kernel size; it computes this from sigma.
    public var sigma: Float = 4.0 {
        didSet { rebuildKernel() }
    }

    private var kernel: MPSImageGaussianBlur
    private let device: MTLDevice

    public init(sigma: Float = 4.0, context: MetalContext = .shared) {
        self.device = context.device
        self.sigma = sigma
        self.kernel = MPSImageGaussianBlur(device: context.device, sigma: sigma)
        kernel.edgeMode = .clamp
    }

    private func rebuildKernel() {
        kernel = MPSImageGaussianBlur(device: device, sigma: sigma)
        kernel.edgeMode = .clamp
    }

    public func encode(encoder: MTLComputeCommandEncoder, input: MTLTexture, output: MTLTexture) {
        // MPS kernels need a command buffer, not a compute encoder.
        // This is a design mismatch with the MetalFilter protocol.
        // For production, use MPSGaussianBlurFilter.encode(commandBuffer:...) directly
        // or integrate it as a special case in the FilterChain.
        //
        // As a workaround, we end the encoder here and use MPS's own encoding.
        // The FilterChain should detect MPS filters and handle them specially.
        // See the MPSFilterChainAdapter below.
    }

    /// Direct encoding into a command buffer (preferred path for MPS filters).
    public func encode(commandBuffer: MTLCommandBuffer, input: MTLTexture, output: MTLTexture) {
        kernel.encode(commandBuffer: commandBuffer, sourceTexture: input, destinationTexture: output)
    }
}

// MARK: - MPS Lanczos Scale (High-Quality Resize)

/// High-quality image scaling using MPS's Lanczos resampling.
/// Useful for downsampling camera frames to model input size (e.g., for style transfer)
/// or upsampling processed results back to display resolution.
public final class MPSScaleFilter {

    private let scaleKernel: MPSImageLanczosScale

    public init(context: MetalContext = .shared) {
        self.scaleKernel = MPSImageLanczosScale(device: context.device)
    }

    /// Scale `input` to the dimensions of `output`.
    public func encode(commandBuffer: MTLCommandBuffer, input: MTLTexture, output: MTLTexture) {
        // MPSImageLanczosScale auto-scales to the output texture dimensions.
        scaleKernel.encode(commandBuffer: commandBuffer, sourceTexture: input, destinationTexture: output)
    }
}

// MARK: - MPS Image Histogram (For Auto-Exposure / Auto-White-Balance)

/// Computes a histogram of the image for auto-exposure analysis.
public final class MPSHistogramCalculator {

    private let histogram: MPSImageHistogram
    private let histogramBuffer: MTLBuffer
    private let device: MTLDevice

    /// Number of bins per channel.
    public let binCount: Int = 256

    public init(context: MetalContext = .shared) {
        self.device = context.device

        var info = MPSImageHistogramInfo(
            numberOfHistogramEntries: 256,
            histogramForAlpha: false,
            minPixelValue: vector_float4(0, 0, 0, 0),
            maxPixelValue: vector_float4(1, 1, 1, 1)
        )

        histogram = MPSImageHistogram(device: device, histogramInfo: &info)

        // Buffer size: 256 entries * 4 channels * sizeof(uint32)
        let bufferSize = histogram.histogramSize(forSourceFormat: .bgra8Unorm)
        histogramBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)!
        histogramBuffer.label = "Histogram_Buffer"
    }

    /// Compute the histogram. Access results via `getHistogram()` after the command buffer completes.
    public func encode(commandBuffer: MTLCommandBuffer, source: MTLTexture) {
        histogram.encode(to: commandBuffer, sourceTexture: source,
                         histogram: histogramBuffer, histogramOffset: 0)
    }

    /// Read the histogram data (call after command buffer completion).
    /// Returns arrays of 256 UInt32 values for R, G, B channels.
    public func getHistogram() -> (red: [UInt32], green: [UInt32], blue: [UInt32]) {
        let ptr = histogramBuffer.contents().bindMemory(to: UInt32.self, capacity: 256 * 4)
        var red   = [UInt32](repeating: 0, count: 256)
        var green = [UInt32](repeating: 0, count: 256)
        var blue  = [UInt32](repeating: 0, count: 256)

        // MPS histogram layout: interleaved RGBA.
        for i in 0..<256 {
            red[i]   = ptr[i * 4 + 0]
            green[i] = ptr[i * 4 + 1]
            blue[i]  = ptr[i * 4 + 2]
        }
        return (red, green, blue)
    }

    /// Quick analysis: compute average brightness from the histogram.
    public func averageBrightness() -> Float {
        let (r, g, b) = getHistogram()
        var totalWeight: UInt64 = 0
        var totalPixels: UInt64 = 0
        for i in 0..<256 {
            let count = UInt64(r[i]) + UInt64(g[i]) + UInt64(b[i])
            totalWeight += UInt64(i) * count
            totalPixels += count
        }
        guard totalPixels > 0 else { return 0 }
        return Float(totalWeight) / Float(totalPixels) / 255.0
    }
}

// MARK: - MPS Sobel Edge Detection

/// Edge detection using MPS, useful for stylisation effects or focus peaking.
public final class MPSSobelFilter: MetalFilter {

    public let name = "MPS_Sobel"
    public var isEnabled: Bool = true

    private let sobel: MPSImageSobel

    public init(context: MetalContext = .shared) {
        self.sobel = MPSImageSobel(device: context.device)
    }

    public func encode(encoder: MTLComputeCommandEncoder, input: MTLTexture, output: MTLTexture) {
        // Same MPS limitation — needs command buffer. See note in MPSGaussianBlurFilter.
    }

    public func encode(commandBuffer: MTLCommandBuffer, input: MTLTexture, output: MTLTexture) {
        sobel.encode(commandBuffer: commandBuffer, sourceTexture: input, destinationTexture: output)
    }
}

// MARK: - MPS-Aware Filter Chain Extension

extension FilterChain {

    /// Encodes the filter chain with special handling for MPS filters.
    /// MPS filters need direct command buffer access rather than a compute encoder.
    @discardableResult
    public func encodeWithMPS(commandBuffer: MTLCommandBuffer,
                              sourceTexture: MTLTexture,
                              texturePool: TexturePool) -> MTLTexture {

        let enabledFilters = filters.filter { $0.isEnabled }
        guard !enabledFilters.isEmpty else { return sourceTexture }

        let w = sourceTexture.width
        let h = sourceTexture.height
        let texA = texturePool.checkout(width: w, height: h)
        let texB = texturePool.checkout(width: w, height: h)

        var currentInput = sourceTexture
        var currentOutput = texA
        var lastWritten = texA

        for (index, filter) in enabledFilters.enumerated() {
            if index > 0 {
                currentInput = lastWritten
                currentOutput = (lastWritten === texA) ? texB : texA
            }

            // Check if this is an MPS filter that needs command buffer access.
            if let mpsBlur = filter as? MPSGaussianBlurFilter {
                mpsBlur.encode(commandBuffer: commandBuffer, input: currentInput, output: currentOutput)
            } else if let mpsSobel = filter as? MPSSobelFilter {
                mpsSobel.encode(commandBuffer: commandBuffer, input: currentInput, output: currentOutput)
            } else {
                // Standard compute filter.
                guard let encoder = commandBuffer.makeComputeCommandEncoder() else { continue }
                encoder.label = filter.name
                filter.encode(encoder: encoder, input: currentInput, output: currentOutput)
                encoder.endEncoding()
            }

            lastWritten = currentOutput
        }

        let unused = (lastWritten === texA) ? texB : texA
        texturePool.checkin(unused)

        return lastWritten
    }
}
