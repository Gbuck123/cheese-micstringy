// BoothSession.swift
// Observable session model that drives the entire booth UI.

import SwiftUI
import os

private let logger = Logger(subsystem: "com.photobooth.ui", category: "BoothSession")

/// The central observable object that drives all UI state transitions.
/// Screens read from this and call its navigation methods.
@Observable
public final class BoothSession {

    // MARK: - Published State

    /// The currently displayed screen.
    public private(set) var currentScreen: BoothScreen = .attract
    /// The previously displayed screen (for transition direction).
    public private(set) var previousScreen: BoothScreen?
    /// The selected capture mode for this session.
    public var selectedMode: CaptureMode = .photo
    /// Captured images from this session (multi-shot support).
    public var capturedImages: [UIImage] = []
    /// The index of the currently reviewed image.
    public var reviewIndex: Int = 0
    /// Whether the session is actively capturing.
    public var isCapturing: Bool = false
    /// Current countdown value (only meaningful on countdown screen).
    public var countdownValue: Int = 3
    /// Whether the booth is in an idle/dimmed state.
    public var isIdle: Bool = false
    /// Error message to display, if any.
    public var errorMessage: String?

    // MARK: - Configuration

    public let config: BoothConfiguration

    // MARK: - Init

    public init(config: BoothConfiguration = BoothConfiguration()) {
        self.config = config
        self.countdownValue = config.countdownDuration
    }

    // MARK: - Navigation

    /// Transition to a new screen. Validates the transition is legal.
    public func navigate(to screen: BoothScreen) {
        guard isValidTransition(from: currentScreen, to: screen) else {
            logger.warning("Invalid transition: \(self.currentScreen.rawValue) -> \(screen.rawValue)")
            return
        }
        logger.info("Navigating: \(self.currentScreen.rawValue) -> \(screen.rawValue)")
        previousScreen = currentScreen
        currentScreen = screen
    }

    /// Reset the session and return to attract screen.
    public func reset() {
        logger.info("Session reset")
        capturedImages.removeAll()
        reviewIndex = 0
        isCapturing = false
        countdownValue = config.countdownDuration
        errorMessage = nil
        selectedMode = .photo
        previousScreen = currentScreen
        currentScreen = .attract
    }

    // MARK: - Capture Management

    /// Add a captured image to the session.
    public func addCapturedImage(_ image: UIImage) {
        capturedImages.append(image)
        logger.info("Captured image \(self.capturedImages.count)/\(self.config.multiShotCount)")
    }

    /// Remove a captured image (retake).
    public func retakeCurrentImage() {
        guard capturedImages.indices.contains(reviewIndex) else { return }
        capturedImages.remove(at: reviewIndex)
        if reviewIndex >= capturedImages.count {
            reviewIndex = max(0, capturedImages.count - 1)
        }
    }

    /// Whether all shots have been captured.
    public var allShotsCaptured: Bool {
        capturedImages.count >= config.multiShotCount
    }

    // MARK: - Transition Validation

    private func isValidTransition(from: BoothScreen, to: BoothScreen) -> Bool {
        switch (from, to) {
        case (.attract, .modeSelect): return true
        case (.modeSelect, .countdown): return true
        case (.modeSelect, .attract): return true
        case (.countdown, .capture): return true
        case (.countdown, .attract): return true // Cancel
        case (.capture, .review): return true
        case (.capture, .countdown): return true // Multi-shot: go back for next shot
        case (.review, .sharing): return true
        case (.review, .countdown): return true // Retake
        case (.review, .attract): return true // Cancel
        case (.sharing, .thankYou): return true
        case (.sharing, .attract): return true // Cancel
        case (.thankYou, .attract): return true
        // Any screen can reset to attract (emergency/timeout)
        case (_, .attract): return true
        default: return false
        }
    }
}
