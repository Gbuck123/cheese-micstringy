// TripleBufferController.swift
// Triple-buffering with MTLEvent/MTLFence-based synchronisation for the camera pipeline.
//
// Triple buffering allows:
//   - CPU to prepare frame N+2 while GPU processes frame N+1 and display shows frame N.
//   - Maximum throughput with minimal latency (1 frame of latency vs 2+ for simpler schemes).
//
// This controller manages the buffer rotation and GPU synchronisation primitives.

import Foundation
import Metal

/// Manages triple-buffered resources with fence/event synchronisation.
///
/// The camera pipeline has three stages:
/// 1. **CPU**: Receive camera frame, prepare uniforms, encode command buffer.
/// 2. **GPU**: Execute the filter chain compute dispatches.
/// 3. **Display**: Present the drawable via MTKView.
///
/// With triple buffering, up to 3 frames can be in-flight simultaneously.
/// The `inflightSemaphore` prevents the CPU from getting more than 3 frames ahead.
public final class TripleBufferController {

    // MARK: - Buffer Index

    /// Current buffer index (0, 1, or 2).
    public private(set) var currentIndex: Int = 0

    /// Advance to the next buffer.
    public func advance() {
        currentIndex = (currentIndex + 1) % bufferCount
    }

    // MARK: - Configuration

    public let bufferCount: Int

    // MARK: - Synchronisation

    /// Semaphore that gates frame submission. Wait before encoding, signal on GPU completion.
    public let inflightSemaphore: DispatchSemaphore

    /// MTLEvent for fine-grained GPU-GPU synchronisation between command buffers.
    /// Useful when the filter chain is split across multiple command buffers
    /// (e.g., MPS filters that need their own command buffer).
    public let gpuEvent: MTLEvent?

    /// Monotonically increasing event value for MTLEvent signaling.
    private var eventValue: UInt64 = 0

    // MARK: - Shared Uniform Buffers

    /// Triple-buffered uniform buffer. Each flight has its own region to avoid data races.
    /// Total size = uniformSize * bufferCount. Index with `uniformOffset(for:)`.
    public let uniformBuffer: MTLBuffer?
    public let uniformStride: Int

    // MARK: - Init

    /// - Parameters:
    ///   - device: The Metal device.
    ///   - bufferCount: Number of in-flight frames (default 3).
    ///   - uniformSize: Size of per-frame uniform data. Pass 0 if not using shared uniforms.
    public init(device: MTLDevice, bufferCount: Int = 3, uniformSize: Int = 0) {
        self.bufferCount = bufferCount
        self.inflightSemaphore = DispatchSemaphore(value: bufferCount)

        // MTLEvent for GPU-GPU sync.
        self.gpuEvent = device.makeEvent()

        // Uniform buffer with proper alignment.
        let alignment = 256 // Metal requires 256-byte alignment for buffer offsets.
        self.uniformStride = uniformSize > 0 ? ((uniformSize + alignment - 1) / alignment) * alignment : 0

        if uniformStride > 0 {
            self.uniformBuffer = device.makeBuffer(
                length: uniformStride * bufferCount,
                options: .storageModeShared
            )
            self.uniformBuffer?.label = "TripleBuffer_Uniforms"
        } else {
            self.uniformBuffer = nil
        }
    }

    // MARK: - Uniform Access

    /// Returns the byte offset into the uniform buffer for the current frame.
    public var currentUniformOffset: Int {
        currentIndex * uniformStride
    }

    /// Returns a typed pointer to the current frame's uniform region.
    public func currentUniforms<T>(as type: T.Type) -> UnsafeMutablePointer<T>? {
        guard let buffer = uniformBuffer else { return nil }
        return (buffer.contents() + currentUniformOffset).bindMemory(to: T.self, capacity: 1)
    }

    // MARK: - GPU Event Signaling

    /// Signal the GPU event from a command buffer (call after encoding all work for a frame).
    public func signalEvent(from commandBuffer: MTLCommandBuffer) {
        guard let event = gpuEvent else { return }
        eventValue += 1
        commandBuffer.encodeSignalEvent(event, value: eventValue)
    }

    /// Wait on the GPU event in a command buffer (call before work that depends on the previous frame).
    public func waitForEvent(in commandBuffer: MTLCommandBuffer) {
        guard let event = gpuEvent, eventValue > 0 else { return }
        commandBuffer.encodeWaitForEvent(event, value: eventValue)
    }

    // MARK: - Fence-Based Synchronisation (Alternative)

    /// Creates an MTLFence for synchronising resource access between encoders
    /// within the same command buffer.
    ///
    /// Use fences when:
    /// - Two compute encoders in the same command buffer share a texture.
    /// - A compute encoder writes to a texture that a render encoder reads.
    ///
    /// Do NOT use fences across command buffers — use MTLEvent instead.
    public static func makeFence(device: MTLDevice, label: String = "SharedFence") -> MTLFence? {
        let fence = device.makeFence()
        fence?.label = label
        return fence
    }
}

// MARK: - Usage Example (Documentation)

/*
 Typical usage in the camera pipeline:

 let tripleBuffer = TripleBufferController(device: device, bufferCount: 3, uniformSize: 256)

 // In captureOutput(_:didOutput:from:):
 func processFrame(_ pixelBuffer: CVPixelBuffer) {
     // 1. Wait for an available flight slot.
     tripleBuffer.inflightSemaphore.wait()
     tripleBuffer.advance()

     // 2. Update uniforms for this frame.
     if let ptr = tripleBuffer.currentUniforms(as: MyUniforms.self) {
         ptr.pointee = MyUniforms(time: currentTime, ...)
     }

     // 3. Create and encode the command buffer.
     let cmdBuf = context.makeCommandBuffer()
     // ... encode filter chain ...

     // 4. Signal the semaphore on GPU completion.
     cmdBuf.addCompletedHandler { [weak tripleBuffer] _ in
         tripleBuffer?.inflightSemaphore.signal()
     }

     // 5. Optionally signal the GPU event for inter-command-buffer sync.
     tripleBuffer.signalEvent(from: cmdBuf)

     cmdBuf.commit()
 }
*/
