// HapticEngine.swift
// CoreHaptics-based haptic engine with custom patterns for photo booth interactions.

import CoreHaptics
import UIKit
import os

private let logger = Logger(subsystem: "com.photobooth.ui", category: "HapticEngine")

/// Manages all haptic feedback for the photo booth using CoreHaptics for
/// precise, custom patterns beyond what UIFeedbackGenerator provides.
public final class HapticEngine: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = HapticEngine()

    // MARK: - Properties

    private var engine: CHHapticEngine?
    private var supportsHaptics: Bool = false

    // UIKit generators as fallback for simple haptics.
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private let notificationGenerator = UINotificationFeedbackGenerator()
    private let selectionGenerator = UISelectionFeedbackGenerator()

    // MARK: - Init

    private init() {
        supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        prepareGenerators()
        if supportsHaptics {
            createEngine()
        }
    }

    private func prepareGenerators() {
        impactLight.prepare()
        impactMedium.prepare()
        impactHeavy.prepare()
        notificationGenerator.prepare()
        selectionGenerator.prepare()
    }

    private func createEngine() {
        do {
            engine = try CHHapticEngine()
            engine?.isAutoShutdownEnabled = true

            // Restart engine if it stops.
            engine?.stoppedHandler = { [weak self] reason in
                logger.info("Haptic engine stopped: \(String(describing: reason))")
                self?.restartEngine()
            }

            engine?.resetHandler = { [weak self] in
                logger.info("Haptic engine reset")
                self?.restartEngine()
            }

            try engine?.start()
        } catch {
            logger.error("Failed to create haptic engine: \(error.localizedDescription)")
            supportsHaptics = false
        }
    }

    private func restartEngine() {
        do {
            try engine?.start()
        } catch {
            logger.error("Failed to restart haptic engine: \(error.localizedDescription)")
        }
    }

    // MARK: - Predefined Patterns

    /// Light tap for button presses.
    public func buttonPress() {
        if supportsHaptics {
            playPattern(events: [
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                    ],
                    relativeTime: 0
                )
            ])
        } else {
            impactLight.impactOccurred()
        }
    }

    /// Countdown tick: progressively stronger taps.
    /// - Parameter step: Countdown step (e.g., 3, 2, 1). Lower = stronger.
    public func countdownTick(step: Int) {
        let intensity = Float(1.0 - (Double(step - 1) * 0.2)).clamped(to: 0.3...1.0)
        let sharpness = Float(0.4 + (1.0 - Double(step - 1) * 0.2) * 0.6).clamped(to: 0.4...1.0)

        if supportsHaptics {
            playPattern(events: [
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
                    ],
                    relativeTime: 0
                )
            ])
        } else {
            impactMedium.impactOccurred(intensity: CGFloat(intensity))
        }
    }

    /// Camera shutter haptic: a crisp double-tap simulating a mechanical shutter.
    public func captureShutter() {
        if supportsHaptics {
            playPattern(events: [
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9)
                    ],
                    relativeTime: 0
                ),
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
                    ],
                    relativeTime: 0.08
                )
            ])
        } else {
            impactHeavy.impactOccurred()
        }
    }

    /// Success pattern: ascending double pulse.
    public func success() {
        if supportsHaptics {
            playPattern(events: [
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)
                    ],
                    relativeTime: 0
                ),
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)
                    ],
                    relativeTime: 0.15
                ),
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.4),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2)
                    ],
                    relativeTime: 0.3,
                    duration: 0.2
                )
            ])
        } else {
            notificationGenerator.notificationOccurred(.success)
        }
    }

    /// Error pattern: sharp buzz.
    public func error() {
        if supportsHaptics {
            playPattern(events: [
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
                    ],
                    relativeTime: 0,
                    duration: 0.1
                ),
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
                    ],
                    relativeTime: 0.2,
                    duration: 0.1
                ),
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
                    ],
                    relativeTime: 0.4,
                    duration: 0.1
                )
            ])
        } else {
            notificationGenerator.notificationOccurred(.error)
        }
    }

    /// Selection changed (e.g., swiping between photos).
    public func selectionChanged() {
        selectionGenerator.selectionChanged()
    }

    // MARK: - Pattern Playback

    private func playPattern(events: [CHHapticEvent]) {
        guard supportsHaptics, let engine else { return }
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            logger.error("Failed to play haptic pattern: \(error.localizedDescription)")
        }
    }
}

// MARK: - Float Clamping

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
