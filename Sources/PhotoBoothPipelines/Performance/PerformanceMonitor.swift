// PerformanceMonitor.swift
// GPU frame timing, thermal throttling detection, and adaptive quality control.

import Foundation
import Metal

// MARK: - GPU Frame Timer

/// Records GPU execution times using Metal's command buffer scheduling/completion timestamps.
/// Use these measurements to detect when the GPU is overloaded and trigger quality reduction.
public final class GPUFrameTimer {

    /// Rolling window of frame GPU times in milliseconds.
    private var frameTimes: [Double] = []
    private let windowSize: Int
    private let lock = NSLock()

    /// Average GPU frame time over the rolling window (ms).
    public var averageFrameTimeMS: Double {
        lock.lock()
        defer { lock.unlock() }
        guard !frameTimes.isEmpty else { return 0 }
        return frameTimes.reduce(0, +) / Double(frameTimes.count)
    }

    /// 95th percentile GPU frame time (ms). Useful for detecting occasional spikes.
    public var p95FrameTimeMS: Double {
        lock.lock()
        defer { lock.unlock() }
        guard !frameTimes.isEmpty else { return 0 }
        let sorted = frameTimes.sorted()
        let idx = min(Int(Double(sorted.count) * 0.95), sorted.count - 1)
        return sorted[idx]
    }

    /// Estimated GPU-side FPS.
    public var estimatedFPS: Double {
        let avg = averageFrameTimeMS
        return avg > 0 ? 1000.0 / avg : 0
    }

    public init(windowSize: Int = 60) {
        self.windowSize = windowSize
    }

    /// Attach a completed handler to a command buffer to record its GPU time.
    public func track(commandBuffer: MTLCommandBuffer) {
        commandBuffer.addCompletedHandler { [weak self] cb in
            guard let self = self else { return }
            // GPUStartTime and GPUEndTime are in seconds (Mach absolute time scale).
            let gpuTime = (cb.gpuEndTime - cb.gpuStartTime) * 1000.0 // → milliseconds
            self.lock.lock()
            self.frameTimes.append(gpuTime)
            if self.frameTimes.count > self.windowSize {
                self.frameTimes.removeFirst(self.frameTimes.count - self.windowSize)
            }
            self.lock.unlock()
        }
    }

    public func reset() {
        lock.lock()
        frameTimes.removeAll()
        lock.unlock()
    }
}

// MARK: - Thermal State Monitor

/// Monitors the device's thermal state and provides recommendations for quality adjustment.
/// On iPad, sustained GPU load can cause thermal throttling, reducing clock speeds.
public final class ThermalStateMonitor {

    public enum QualityLevel: Int, Comparable {
        case full    = 0   // All effects at full resolution
        case reduced = 1   // Half-res bloom, reduce blur radius
        case minimal = 2   // Disable expensive effects, lower camera resolution
        case critical = 3  // Only passthrough, save the device

        public static func < (lhs: QualityLevel, rhs: QualityLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Current recommended quality level based on thermal state.
    public private(set) var recommendedQuality: QualityLevel = .full

    /// Callback invoked when the recommended quality level changes.
    public var onQualityChange: ((QualityLevel) -> Void)?

    private var thermalObserver: NSObjectProtocol?

    public init() {
        // Map ProcessInfo.thermalState to our quality levels.
        updateQuality(from: ProcessInfo.processInfo.thermalState)

        // Observe thermal state changes.
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateQuality(from: ProcessInfo.processInfo.thermalState)
        }
    }

    deinit {
        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func updateQuality(from state: ProcessInfo.ThermalState) {
        let newLevel: QualityLevel
        switch state {
        case .nominal:
            newLevel = .full
        case .fair:
            newLevel = .reduced
        case .serious:
            newLevel = .minimal
        case .critical:
            newLevel = .critical
        @unknown default:
            newLevel = .reduced
        }

        if newLevel != recommendedQuality {
            recommendedQuality = newLevel
            onQualityChange?(newLevel)
        }
    }
}

// MARK: - Adaptive Quality Controller

/// Combines GPU timing and thermal state to dynamically adjust the filter chain.
/// This is the production-level quality controller for a photo booth that may run for hours.
public final class AdaptiveQualityController {

    private let frameTimer: GPUFrameTimer
    private let thermalMonitor: ThermalStateMonitor

    /// Target frame time in ms (e.g., 33.3ms for 30fps, 16.7ms for 60fps).
    public var targetFrameTimeMS: Double = 33.3

    /// Headroom factor: if GPU time exceeds target * headroomFactor, reduce quality.
    public var headroomFactor: Double = 0.85

    /// Current effective quality level (the more conservative of thermal and GPU-based).
    public var currentQuality: ThermalStateMonitor.QualityLevel {
        let gpuLevel = gpuBasedQuality()
        return max(gpuLevel, thermalMonitor.recommendedQuality)
    }

    /// Callback when quality level changes.
    public var onQualityChange: ((ThermalStateMonitor.QualityLevel) -> Void)?

    private var lastReportedQuality: ThermalStateMonitor.QualityLevel = .full

    public init(targetFPS: Int = 30) {
        self.frameTimer = GPUFrameTimer(windowSize: 60)
        self.thermalMonitor = ThermalStateMonitor()
        self.targetFrameTimeMS = 1000.0 / Double(targetFPS)

        thermalMonitor.onQualityChange = { [weak self] _ in
            self?.evaluateAndNotify()
        }
    }

    /// Call this to attach timing to each command buffer.
    public func track(commandBuffer: MTLCommandBuffer) {
        frameTimer.track(commandBuffer: commandBuffer)
        // Evaluate after a few frames.
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.evaluateAndNotify()
        }
    }

    private func gpuBasedQuality() -> ThermalStateMonitor.QualityLevel {
        let p95 = frameTimer.p95FrameTimeMS
        let budget = targetFrameTimeMS * headroomFactor

        if p95 < budget * 0.7 {
            return .full
        } else if p95 < budget {
            return .reduced
        } else if p95 < budget * 1.5 {
            return .minimal
        } else {
            return .critical
        }
    }

    private func evaluateAndNotify() {
        let quality = currentQuality
        if quality != lastReportedQuality {
            lastReportedQuality = quality
            DispatchQueue.main.async { [weak self] in
                self?.onQualityChange?(quality)
            }
        }
    }

    /// Apply recommended quality to a filter chain.
    /// This is a convenience method; in production you'd customise this per-app.
    public func apply(to chain: FilterChain) {
        let quality = currentQuality

        for filter in chain.filters {
            switch quality {
            case .full:
                filter.isEnabled = true

            case .reduced:
                // Keep all filters but reduce blur radius, etc.
                filter.isEnabled = true
                if let blur = filter as? GaussianBlurFilter {
                    blur.radius = min(blur.radius, 6)
                }
                if let bloom = filter as? BloomFilter {
                    bloom.blurRadius = min(bloom.blurRadius, 6)
                }

            case .minimal:
                // Disable expensive effects.
                if filter is BloomFilter || filter is GaussianBlurFilter || filter is NeuralStyleTransferFilter {
                    filter.isEnabled = false
                }

            case .critical:
                // Only keep essential filters (e.g., overlay for branding).
                if !(filter is OverlayFilter) {
                    filter.isEnabled = false
                }
            }
        }
    }
}
