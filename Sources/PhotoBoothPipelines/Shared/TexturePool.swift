// TexturePool.swift
// Reusable texture pool to avoid per-frame allocations in the filter chain.

import Foundation
import Metal

/// A pool of MTLTextures with identical dimensions and format.
/// Eliminates allocation overhead in multi-pass filter chains by recycling textures.
public final class TexturePool {

    private let device: MTLDevice
    private let pixelFormat: MTLPixelFormat
    private var available: [MTLTexture] = []
    private let lock = NSLock()

    /// Current texture dimensions. The pool auto-invalidates when dimensions change.
    private(set) var width: Int = 0
    private(set) var height: Int = 0

    public init(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm) {
        self.device = device
        self.pixelFormat = pixelFormat
    }

    /// Checkout a texture that matches the given dimensions.
    /// If none are available (or dimensions changed), a new one is allocated.
    public func checkout(width: Int, height: Int) -> MTLTexture {
        lock.lock()
        defer { lock.unlock() }

        // Invalidate pool on dimension change (e.g., orientation change).
        if width != self.width || height != self.height {
            available.removeAll()
            self.width = width
            self.height = height
        }

        if let texture = available.popLast() {
            return texture
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private

        guard let texture = device.makeTexture(descriptor: desc) else {
            fatalError("[TexturePool] Failed to allocate \(width)x\(height) texture.")
        }
        texture.label = "Pool_\(width)x\(height)"
        return texture
    }

    /// Return a texture to the pool so it can be reused next frame.
    public func checkin(_ texture: MTLTexture) {
        lock.lock()
        defer { lock.unlock() }

        // Only keep textures that match current dimensions.
        guard texture.width == width, texture.height == height else { return }
        available.append(texture)
    }

    /// Discard all pooled textures (call on memory warning).
    public func drain() {
        lock.lock()
        defer { lock.unlock() }
        available.removeAll()
    }
}
