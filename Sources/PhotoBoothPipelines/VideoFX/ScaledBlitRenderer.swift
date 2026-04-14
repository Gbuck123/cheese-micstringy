// ScaledBlitRenderer.swift
// Renders a Metal texture to an MTKView with proper aspect-fit scaling using a render pipeline.
// Use this instead of a raw blit when the processed texture size differs from the MTKView drawable size.

import Foundation
import Metal
import MetalKit

/// Renders a full-screen textured quad with aspect-fit or aspect-fill scaling.
public final class ScaledBlitRenderer {

    public enum ScaleMode {
        case aspectFit
        case aspectFill
        case stretch
    }

    public var scaleMode: ScaleMode = .aspectFit

    private let device: MTLDevice
    private let renderPipelineState: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer
    private let samplerState: MTLSamplerState

    // Full-screen quad: 4 vertices, each with position (x, y) and texcoord (u, v).
    private static let quadVertices: [Float] = [
        // x,    y,    u,   v
        -1.0, -1.0,  0.0, 1.0,   // bottom-left
         1.0, -1.0,  1.0, 1.0,   // bottom-right
        -1.0,  1.0,  0.0, 0.0,   // top-left
         1.0,  1.0,  1.0, 0.0,   // top-right
    ]

    public init(context: MetalContext = .shared) {
        self.device = context.device

        // Create vertex buffer.
        let dataSize = ScaledBlitRenderer.quadVertices.count * MemoryLayout<Float>.size
        vertexBuffer = device.makeBuffer(
            bytes: ScaledBlitRenderer.quadVertices,
            length: dataSize,
            options: .storageModeShared
        )!
        vertexBuffer.label = "BlitQuad_Vertices"

        // Create sampler.
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        samplerState = device.makeSamplerState(descriptor: samplerDesc)!

        // Create render pipeline from the vertex/fragment functions in our Metal library.
        let library = context.library
        let vertexFunction = library.makeFunction(name: "blitVertex")!
        let fragmentFunction = library.makeFunction(name: "blitFragment")!

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertexFunction
        pipelineDesc.fragmentFunction = fragmentFunction
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            renderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)
        } catch {
            fatalError("[ScaledBlitRenderer] Failed to create render pipeline: \(error)")
        }
    }

    /// Render `texture` into the given render pass (typically from MTKView's currentRenderPassDescriptor).
    public func render(texture: MTLTexture,
                       in renderPassDescriptor: MTLRenderPassDescriptor,
                       commandBuffer: MTLCommandBuffer,
                       drawableSize: CGSize) {

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
        encoder.label = "ScaledBlit"
        encoder.setRenderPipelineState(renderPipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }
}
