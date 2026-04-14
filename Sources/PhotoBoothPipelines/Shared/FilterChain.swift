// FilterChain.swift
// Efficient multi-pass filter chain with ping-pong buffering and synchronisation.

import Foundation
import Metal

/// Chains multiple `MetalFilter` instances together, ping-ponging between two intermediate
/// textures to avoid unnecessary copies. All filters execute within a single command buffer.
public final class FilterChain {

    // MARK: Properties

    private let context: MetalContext
    private let texturePool: TexturePool
    private(set) var filters: [MetalFilter] = []

    /// Current time tracking for animated filters.
    private var startTime: CFAbsoluteTime = 0
    private var lastFrameTime: CFAbsoluteTime = 0

    // MARK: Init

    public init(context: MetalContext = .shared) {
        self.context = context
        self.texturePool = TexturePool(device: context.device)
        self.startTime = CFAbsoluteTimeGetCurrent()
        self.lastFrameTime = startTime
    }

    // MARK: Filter Management

    public func append(_ filter: MetalFilter) {
        filters.append(filter)
    }

    public func insert(_ filter: MetalFilter, at index: Int) {
        filters.insert(filter, at: index)
    }

    public func remove(at index: Int) {
        filters.remove(at: index)
    }

    public func removeAll() {
        filters.removeAll()
    }

    // MARK: Encoding

    /// Encode the full filter chain into a command buffer.
    ///
    /// **Ping-pong strategy**: Two intermediate textures (A and B) alternate as input/output
    /// across passes, eliminating texture copies between stages.
    ///
    /// The first enabled filter reads from `sourceTexture` and writes to A.
    /// The second reads from A and writes to B.
    /// The third reads from B and writes to A.  ...and so on.
    /// The final output is the texture most recently written.
    ///
    /// If no filters are enabled, returns `sourceTexture` unmodified (zero-cost passthrough).
    ///
    /// - Parameters:
    ///   - commandBuffer: The command buffer to encode into.
    ///   - sourceTexture: Camera frame or previous-stage output.
    /// - Returns: The texture containing the final processed result.
    @discardableResult
    public func encode(commandBuffer: MTLCommandBuffer,
                       sourceTexture: MTLTexture) -> MTLTexture {

        // Update time for animated filters.
        let now = CFAbsoluteTimeGetCurrent()
        let time = now - startTime
        let delta = now - lastFrameTime
        lastFrameTime = now

        let enabledFilters = filters.filter { $0.isEnabled }
        guard !enabledFilters.isEmpty else { return sourceTexture }

        // Checkout two ping-pong textures from the pool.
        let w = sourceTexture.width
        let h = sourceTexture.height
        let texA = texturePool.checkout(width: w, height: h)
        let texB = texturePool.checkout(width: w, height: h)

        var currentInput = sourceTexture
        var currentOutput = texA
        var lastWritten = texA

        for (index, filter) in enabledFilters.enumerated() {
            // Update animated filters.
            if let animatable = filter as? AnimatableFilter {
                animatable.update(time: time, deltaTime: delta)
            }

            // Determine output: for the last filter, write to the "last" ping-pong texture
            // so we know which one to return.
            if index > 0 {
                currentInput = lastWritten
                currentOutput = (lastWritten === texA) ? texB : texA
            }

            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { continue }
            encoder.label = filter.name
            filter.encode(encoder: encoder, input: currentInput, output: currentOutput)
            encoder.endEncoding()

            lastWritten = currentOutput
        }

        // Return textures we did NOT write the final result to.
        let unused = (lastWritten === texA) ? texB : texA
        texturePool.checkin(unused)
        // The caller should call returnFinalTexture() once the GPU finishes with lastWritten.

        return lastWritten
    }

    /// Call after the command buffer completes to return the final texture to the pool.
    public func returnTexture(_ texture: MTLTexture) {
        texturePool.checkin(texture)
    }

    /// Release pooled textures on memory pressure.
    public func handleMemoryWarning() {
        texturePool.drain()
    }
}
