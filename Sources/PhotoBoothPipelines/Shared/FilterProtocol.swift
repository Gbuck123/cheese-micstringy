// FilterProtocol.swift
// Protocol that all Metal compute filters conform to, enabling composable filter chains.

import Metal

/// A single image-processing filter that reads from an input texture and writes to an output texture
/// within a single compute command encoder.
public protocol MetalFilter: AnyObject {

    /// Human-readable name for debugging and GPU capture labels.
    var name: String { get }

    /// Whether this filter is currently enabled in the chain.
    var isEnabled: Bool { get set }

    /// Encode compute commands for this filter into the given encoder.
    /// - Parameters:
    ///   - encoder: An active MTLComputeCommandEncoder.
    ///   - input:   Source texture (read-only).
    ///   - output:  Destination texture (write-only). May be the same as the next stage's input.
    func encode(encoder: MTLComputeCommandEncoder, input: MTLTexture, output: MTLTexture)
}

/// Optional protocol for filters that need per-frame uniform updates (e.g., time-based animations).
public protocol AnimatableFilter: MetalFilter {
    /// Called once per frame before encoding. `time` is seconds since filter chain start.
    func update(time: Double, deltaTime: Double)
}

/// Optional protocol for filters that require additional texture resources (e.g., LUT, overlay).
public protocol TextureResourceFilter: MetalFilter {
    /// Called once to provide auxiliary textures. The filter retains them.
    func setAuxiliaryTextures(_ textures: [String: MTLTexture])
}
