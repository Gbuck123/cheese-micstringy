// BoothConfiguration.swift
// All configurable parameters for a photo booth event, loaded at runtime.

import Foundation
import SwiftUI

/// Configuration for a single photo booth event. Typically loaded from a server
/// or local JSON file before the booth session starts.
@Observable
public final class BoothConfiguration {

    // MARK: - Attract Screen

    /// URL to the attract loop video. Nil means fall back to static image.
    public var attractVideoURL: URL?
    /// Name of the static attract image in the asset catalog.
    public var attractImageName: String = "attract_default"
    /// Seconds of inactivity before the screen dims.
    public var idleDimTimeout: TimeInterval = 120
    /// Dimmed brightness level (0.0 to 1.0).
    public var dimmedBrightness: CGFloat = 0.3

    // MARK: - Countdown

    /// Number of seconds to count down before capture.
    public var countdownDuration: Int = 3
    /// Whether to play a shutter sound on capture.
    public var shutterSoundEnabled: Bool = true
    /// Whether to flash the screen on capture.
    public var flashEffectEnabled: Bool = true

    // MARK: - Capture Modes

    /// Which capture modes are enabled for this event.
    public var enabledModes: Set<CaptureMode> = [.photo, .gif, .boomerang]
    /// Number of photos in a multi-shot session (e.g., photo strip).
    public var multiShotCount: Int = 4

    // MARK: - Review

    /// Seconds before auto-keeping photos if the user does not act.
    public var reviewAutoAdvanceTimeout: TimeInterval = 30
    /// Whether pinch-to-zoom is enabled on the review screen.
    public var pinchToZoomEnabled: Bool = true

    // MARK: - Sharing

    /// Which sharing options are enabled for this event.
    public var enabledSharingOptions: Set<SharingOption> = Set(SharingOption.allCases)
    /// Base URL for generating QR codes that link to the photo gallery.
    public var galleryBaseURL: URL? = URL(string: "https://gallery.example.com")
    /// Seconds on the thank-you screen before returning to attract.
    public var thankYouTimeout: TimeInterval = 8

    // MARK: - Branding

    /// Event name displayed on various screens.
    public var eventName: String = "Photo Booth"
    /// Primary brand color.
    public var primaryColor: Color = .blue
    /// Secondary brand color.
    public var secondaryColor: Color = .purple
    /// Template overlay image name to composite on captured photos.
    public var templateOverlayName: String?

    // MARK: - Kiosk

    /// Whether Guided Access should be requested on launch.
    public var guidedAccessEnabled: Bool = true
    /// Whether to suppress system notifications.
    public var suppressNotifications: Bool = true

    // MARK: - Localization

    /// The preferred locale for the booth. Nil = system default.
    public var preferredLocale: Locale?
    /// Available languages for the language picker.
    public var availableLanguages: [String] = ["en", "es", "fr", "de", "ja", "zh-Hans"]

    public init() {}
}
