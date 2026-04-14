// MetalDebugCapture.swift
// Programmatic GPU frame capture for debugging and profiling.
// Integrates with Xcode's Metal debugger and Metal System Trace.

import Foundation
import Metal

/// Provides programmatic GPU frame capture and profiling helpers.
///
/// ## How to Use Metal Debugging Tools
///
/// ### 1. GPU Frame Capture (Xcode Metal Debugger)
///
/// In Xcode: Edit Scheme → Run → Options → GPU Frame Capture → Metal.
/// Then in the debug bar, click the camera icon to capture a frame.
///
/// Programmatically (useful for capturing specific frames during automated testing):
/// ```swift
/// MetalDebugCapture.shared.captureNextFrame()
/// ```
///
/// ### 2. Metal System Trace (Instruments)
///
/// Profile → Metal System Trace template.
/// Shows: GPU utilization, encoder boundaries, memory bandwidth, shader execution.
/// Key metrics to watch:
/// - GPU Active Time %
/// - Vertex/Fragment/Compute occupancy
/// - Texture bandwidth
///
/// ### 3. GPU Counter Sampling
///
/// Use `MTLCounterSampleBuffer` to read GPU performance counters directly.
/// Available counters vary by device but typically include:
/// - Shader ALU utilization
/// - Texture cache hit rate
/// - Memory bandwidth
///
public final class MetalDebugCapture {

    public static let shared = MetalDebugCapture()

    private let captureManager = MTLCaptureManager.shared()
    private var captureScope: MTLCaptureScope?

    private init() {}

    /// Set up a named capture scope for the photo booth pipeline.
    /// Call once during initialization.
    public func setup(device: MTLDevice, label: String = "PhotoBooth Pipeline") {
        let scope = captureManager.makeCaptureScope(device: device)
        scope.label = label
        captureScope = scope

        // Set as the default scope so Xcode's capture button uses it.
        captureManager.defaultCaptureScope = scope
    }

    /// Begin a capture scope boundary. Call before encoding the frame's command buffers.
    public func beginScope() {
        captureScope?.begin()
    }

    /// End a capture scope boundary. Call after committing the frame's command buffers.
    public func endScope() {
        captureScope?.end()
    }

    /// Programmatically capture the next frame to a file.
    /// The .gputrace file can be opened in Xcode for analysis.
    public func captureToFile(url: URL, device: MTLDevice) {
        guard captureManager.supportsDestination(.gpuTraceDocument) else {
            print("[MetalDebugCapture] GPU trace document capture not supported.")
            return
        }

        let descriptor = MTLCaptureDescriptor()
        descriptor.captureObject = device
        descriptor.destination = .gpuTraceDocument
        descriptor.outputURL = url

        do {
            try captureManager.startCapture(with: descriptor)
            print("[MetalDebugCapture] Capture started → \(url.path)")
        } catch {
            print("[MetalDebugCapture] Failed to start capture: \(error)")
        }
    }

    /// Stop an in-progress file capture.
    public func stopCapture() {
        if captureManager.isCapturing {
            captureManager.stopCapture()
            print("[MetalDebugCapture] Capture stopped.")
        }
    }

    /// Capture a single frame's worth of GPU work.
    /// Wraps the frame's encoding in a capture scope and triggers Xcode capture.
    public func captureFrame(device: MTLDevice, work: () -> Void) {
        guard captureManager.supportsDestination(.developerTools) else {
            work()
            return
        }

        let descriptor = MTLCaptureDescriptor()
        descriptor.captureObject = device
        descriptor.destination = .developerTools

        do {
            try captureManager.startCapture(with: descriptor)
            work()
            captureManager.stopCapture()
        } catch {
            print("[MetalDebugCapture] Frame capture failed: \(error)")
            work()
        }
    }
}

// MARK: - Performance Annotations

extension MTLCommandBuffer {

    /// Push a debug group for the GPU frame capture timeline.
    /// Visible in Xcode's Metal debugger and Instruments.
    func pushDebugScope(_ label: String) {
        pushDebugGroup(label)
    }

    /// Pop the debug group.
    func popDebugScope() {
        popDebugGroup()
    }
}

extension MTLComputeCommandEncoder {

    /// Insert a debug signpost visible in Instruments' Metal System Trace.
    func insertDebugMark(_ label: String) {
        insertDebugSignpost(label)
    }
}

// MARK: - Memory Usage Tracking

public extension MetalContext {

    /// Returns the current allocated heap size in bytes (Apple GPUs only).
    /// Useful for tracking texture memory growth in long-running photo booth sessions.
    var currentAllocatedSize: Int {
        return device.currentAllocatedSize
    }

    /// Returns a human-readable string of the current GPU memory usage.
    var memoryUsageDescription: String {
        let bytes = currentAllocatedSize
        let mb = Double(bytes) / 1_048_576.0
        return String(format: "GPU Memory: %.1f MB", mb)
    }
}
