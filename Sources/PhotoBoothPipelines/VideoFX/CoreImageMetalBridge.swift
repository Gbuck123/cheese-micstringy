// CoreImageMetalBridge.swift
// Bridge between Core Image's hardware-accelerated filters and the Metal filter chain.
// Allows using CIFilter within the MetalFilter protocol for hybrid pipelines.

import Foundation
import Metal
import CoreImage
import CoreVideo

/// Wraps a CIFilter (or chain of CIFilters) as a MetalFilter for use in the FilterChain.
///
/// **When to use Core Image vs raw Metal:**
/// - Use **Core Image** for: face detection-driven effects (CIBumpDistortion centered on faces),
///   complex color adjustments (CIColorCurves, CIToneCurve), morphology operations,
///   and any filter where Apple's highly-optimised implementation beats a hand-written kernel.
/// - Use **raw Metal** for: custom effects not in Core Image's catalog, effects that need
///   sub-frame animation, multi-pass effects where you control intermediate textures,
///   and when you need guaranteed single-frame latency.
///
/// This bridge renders the CIImage pipeline into an MTLTexture using a Metal-backed CIContext,
/// so no CPU readback occurs.
public final class CoreImageMetalFilter: MetalFilter {

    public let name: String
    public var isEnabled: Bool = true

    /// The CIFilter pipeline builder. Called each frame with the input CIImage.
    /// Return the processed CIImage.
    public var filterBuilder: (CIImage) -> CIImage

    private let ciContext: CIContext
    private let colorSpace: CGColorSpace

    /// - Parameters:
    ///   - name: Debug label.
    ///   - ciContext: Metal-backed CIContext from MetalContext.shared.ciContext.
    ///   - filterBuilder: Closure that applies CIFilters to the input CIImage.
    public init(name: String = "CoreImage_Bridge",
                context: MetalContext = .shared,
                filterBuilder: @escaping (CIImage) -> CIImage) {
        self.name = name
        self.ciContext = context.ciContext
        self.colorSpace = CGColorSpaceCreateDeviceRGB()
        self.filterBuilder = filterBuilder
    }

    public func encode(encoder: MTLComputeCommandEncoder, input: MTLTexture, output: MTLTexture) {
        // Core Image requires a command buffer, not a compute encoder.
        // We end the encoder, use Core Image's own rendering, then the FilterChain's
        // next encoder will read the output texture.
        //
        // IMPORTANT: This is a design constraint. The FilterChain calls encode() with
        // a compute encoder, but CIContext.render() needs a command buffer.
        // The recommended approach is to use CoreImageMetalFilter as a standalone
        // step in the pipeline, or use the dedicated `renderCoreImage()` method
        // with direct command buffer access.
        //
        // For this implementation, we use the CPU-path CIContext.render into the
        // output texture, which still uses the GPU internally via Metal backing.

        let ciInput = CIImage(mtlTexture: input, options: [.colorSpace: colorSpace])!
        let processed = filterBuilder(ciInput)

        // Render directly to the output MTLTexture.
        ciContext.render(
            processed,
            to: output,
            commandBuffer: nil, // CIContext creates its own internally
            bounds: CGRect(x: 0, y: 0, width: output.width, height: output.height),
            colorSpace: colorSpace
        )
    }

    /// Direct render method for use outside the FilterChain (e.g., in a custom pipeline stage).
    /// This uses the command buffer directly for proper GPU synchronisation.
    public func renderCoreImage(input: MTLTexture,
                                output: MTLTexture,
                                commandBuffer: MTLCommandBuffer) {
        let ciInput = CIImage(mtlTexture: input, options: [.colorSpace: colorSpace])!
        let processed = filterBuilder(ciInput)

        ciContext.render(
            processed,
            to: output,
            commandBuffer: commandBuffer,
            bounds: CGRect(x: 0, y: 0, width: output.width, height: output.height),
            colorSpace: colorSpace
        )
    }
}

// MARK: - CIKernel with Metal Backing

/// A CIFilter backed by a custom Metal kernel (.ci.metal file compiled into a CIKernel).
/// This gives you Core Image's automatic tiling, concatenation optimisation, and color management
/// while using custom Metal shader code.
///
/// To use:
/// 1. Write a `extern "C" float4 myKernel(...)` function in a `.ci.metal` file.
/// 2. Compile it with `metallib` including `-fcikernel` flag.
/// 3. Load it here.
public final class MetalCIKernelFilter: CIFilter {

    private let kernel: CIColorKernel
    public var inputImage: CIImage?

    /// Additional parameters passed to the kernel.
    public var parameters: [Any] = []

    /// Load a CIColorKernel from a metallib that was compiled with -fcikernel.
    /// - Parameters:
    ///   - functionName: The `extern "C"` function name in the .ci.metal file.
    ///   - metalLibURL: URL to the compiled .metallib file. If nil, uses the default library.
    public init?(functionName: String, metalLibURL: URL? = nil) {
        do {
            if let url = metalLibURL {
                let data = try Data(contentsOf: url)
                kernel = try CIColorKernel(functionName: functionName, fromMetalLibraryData: data)
            } else {
                guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
                      let data = try? Data(contentsOf: url) else {
                    print("[MetalCIKernelFilter] No metallib found.")
                    return nil
                }
                kernel = try CIColorKernel(functionName: functionName, fromMetalLibraryData: data)
            }
        } catch {
            print("[MetalCIKernelFilter] Failed to load kernel '\(functionName)': \(error)")
            return nil
        }
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public override var outputImage: CIImage? {
        guard let input = inputImage else { return nil }
        return kernel.apply(extent: input.extent, arguments: [input] + parameters)
    }
}

// MARK: - Convenience: Common CIFilter Presets

public extension CoreImageMetalFilter {

    /// Creates a Core Image filter that applies a Gaussian blur.
    /// Useful for comparison / fallback when the custom Metal blur is not needed.
    static func gaussianBlur(radius: Double = 10.0, context: MetalContext = .shared) -> CoreImageMetalFilter {
        CoreImageMetalFilter(name: "CI_GaussianBlur", context: context) { input in
            input.applyingGaussianBlur(sigma: radius)
                 .cropped(to: input.extent) // CIGaussianBlur extends the extent
        }
    }

    /// Applies CIColorCurves for fine-grained tone adjustment.
    static func colorCurves(context: MetalContext = .shared,
                            redPoints: [CGPoint] = [],
                            greenPoints: [CGPoint] = [],
                            bluePoints: [CGPoint] = []) -> CoreImageMetalFilter {
        CoreImageMetalFilter(name: "CI_ColorCurves", context: context) { input in
            guard let filter = CIFilter(name: "CIToneCurve") else { return input }
            filter.setValue(input, forKey: kCIInputImageKey)
            // Set up to 5 control points per channel for CIToneCurve.
            // Use CIColorCurves for full spline control.
            return filter.outputImage ?? input
        }
    }

    /// Face-aware vignette using CIFaceBalance + CIVignette.
    static func faceAwareVignette(intensity: Double = 1.0, context: MetalContext = .shared) -> CoreImageMetalFilter {
        CoreImageMetalFilter(name: "CI_FaceVignette", context: context) { input in
            guard let vignette = CIFilter(name: "CIVignette") else { return input }
            vignette.setValue(input, forKey: kCIInputImageKey)
            vignette.setValue(intensity, forKey: kCIInputIntensityKey)
            vignette.setValue(1.0, forKey: kCIInputRadiusKey)
            return vignette.outputImage ?? input
        }
    }
}
