// MetalContext.swift
// Shared Metal device, command queue, and pipeline state management.

import Foundation
import Metal
import MetalKit
import MetalPerformanceShaders
import CoreVideo
import CoreImage

// MARK: - MetalContext (Singleton)

/// Central Metal context that owns the device, command queue, and texture cache.
/// All pipeline stages share this to avoid redundant resource creation.
public final class MetalContext {

    // MARK: Singleton

    public static let shared: MetalContext = {
        guard let ctx = MetalContext() else {
            fatalError("[MetalContext] No Metal-capable GPU found on this device.")
        }
        return ctx
    }()

    // MARK: Core Objects

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let library: MTLLibrary
    public let ciContext: CIContext

    // CVMetalTextureCache for zero-copy camera frame → MTLTexture conversion
    public let textureCache: CVMetalTextureCache

    // MARK: Init

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device

        guard let queue = device.makeCommandQueue() else { return nil }
        queue.label = "com.photobooth.mainCommandQueue"
        self.commandQueue = queue

        // Load the default Metal library that contains all .metal shaders compiled
        // into the app bundle.
        guard let library = device.makeDefaultLibrary() else {
            fatalError("[MetalContext] Failed to load default Metal library. Ensure .metal files are in the target.")
        }
        self.library = library

        // Core Image context backed by the same Metal device — avoids CPU round-trips.
        self.ciContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
            .cacheIntermediates: true
        ])

        // Texture cache for CVPixelBuffer → MTLTexture.
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        guard status == kCVReturnSuccess, let unwrapped = cache else {
            fatalError("[MetalContext] CVMetalTextureCacheCreate failed: \(status)")
        }
        self.textureCache = unwrapped
    }

    // MARK: - Pipeline State Factory

    private var pipelineCache: [String: MTLComputePipelineState] = [:]
    private let cacheLock = NSLock()

    /// Returns a cached compute pipeline state for the named kernel function.
    public func computePipeline(function name: String) -> MTLComputePipelineState {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let cached = pipelineCache[name] { return cached }

        guard let function = library.makeFunction(name: name) else {
            fatalError("[MetalContext] Kernel function '\(name)' not found in Metal library.")
        }
        do {
            let state = try device.makeComputePipelineState(function: function)
            pipelineCache[name] = state
            return state
        } catch {
            fatalError("[MetalContext] Failed to create pipeline state for '\(name)': \(error)")
        }
    }

    // MARK: - Texture Helpers

    /// Create a reusable BGRA8 texture of the given size (used for intermediate ping-pong buffers).
    public func makeTexture(width: Int, height: Int,
                            pixelFormat: MTLPixelFormat = .bgra8Unorm,
                            usage: MTLTextureUsage = [.shaderRead, .shaderWrite]) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = usage
        desc.storageMode = .private  // GPU-only; fastest on Apple Silicon
        guard let texture = device.makeTexture(descriptor: desc) else {
            fatalError("[MetalContext] Failed to allocate texture \(width)x\(height)")
        }
        return texture
    }

    /// Convert a CVPixelBuffer (from the camera) to an MTLTexture using the texture cache.
    /// This is a zero-copy operation on Apple Silicon — the GPU reads the IOSurface-backed buffer directly.
    public func texture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,  // plane index
            &cvTexture
        )

        guard status == kCVReturnSuccess, let unwrapped = cvTexture else {
            return nil
        }

        return CVMetalTextureGetTexture(unwrapped)
    }

    /// Flush the texture cache (call periodically to reclaim memory, e.g., every N frames).
    public func flushTextureCache() {
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    // MARK: - Command Buffer Helpers

    /// Creates a command buffer with an optional label for GPU frame-capture debugging.
    public func makeCommandBuffer(label: String = "PhotoBooth") -> MTLCommandBuffer {
        guard let buffer = commandQueue.makeCommandBuffer() else {
            fatalError("[MetalContext] Failed to create command buffer.")
        }
        buffer.label = label
        return buffer
    }
}

// MARK: - Threadgroup Size Utility

public extension MTLComputePipelineState {

    /// Computes optimal threadgroup size and grid dimensions for a 2D texture dispatch.
    func threadgroupParameters(for texture: MTLTexture) -> (threadsPerGrid: MTLSize, threadsPerThreadgroup: MTLSize) {
        let w = threadExecutionWidth
        let h = maxTotalThreadsPerThreadgroup / w
        let threadsPerThreadgroup = MTLSize(width: w, height: h, depth: 1)
        let threadsPerGrid = MTLSize(width: texture.width, height: texture.height, depth: 1)
        return (threadsPerGrid, threadsPerThreadgroup)
    }
}
