// AccessibilityModifiers.swift
// VoiceOver, Dynamic Type, and RTL support utilities for the photo booth.

import SwiftUI

// MARK: - Booth Accessibility Label Modifier

/// Provides consistent accessibility labeling across booth screens.
struct BoothAccessibilityModifier: ViewModifier {
    let label: LocalizedStringKey
    let hint: LocalizedStringKey?
    let isButton: Bool

    init(label: LocalizedStringKey, hint: LocalizedStringKey? = nil, isButton: Bool = false) {
        self.label = label
        self.hint = hint
        self.isButton = isButton
    }

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(label))
            .if(hint != nil) { view in
                view.accessibilityHint(Text(hint!))
            }
            .if(isButton) { view in
                view.accessibilityAddTraits(.isButton)
            }
    }
}

// MARK: - Conditional Modifier

extension View {
    /// Apply a modifier conditionally.
    @ViewBuilder
    func `if`<Transform: View>(_ condition: Bool, transform: (Self) -> Transform) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - Dynamic Type Clamping

/// Clamps Dynamic Type to a range appropriate for kiosk use.
/// We support Dynamic Type but limit extremes since the kiosk
/// has a fixed viewing distance.
struct ClampedDynamicTypeModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content
            .dynamicTypeSize(.small ... .xxxLarge)
    }
}

extension View {
    /// Apply kiosk-appropriate Dynamic Type limits.
    func kioskDynamicType() -> some View {
        modifier(ClampedDynamicTypeModifier())
    }
}

// MARK: - Announcement Helpers

/// Post a VoiceOver announcement.
func announceForAccessibility(_ message: String) {
    UIAccessibility.post(notification: .announcement, argument: message)
}

/// Post a screen change notification for VoiceOver.
func announceScreenChange(_ message: String? = nil) {
    UIAccessibility.post(notification: .screenChanged, argument: message)
}

// MARK: - RTL-Aware Layout

/// A horizontal stack that respects layout direction for RTL languages.
struct RTLAwareHStack<Content: View>: View {
    @Environment(\.layoutDirection) private var layoutDirection

    let spacing: CGFloat
    let content: () -> Content

    init(spacing: CGFloat = 8, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        HStack(spacing: spacing) {
            content()
        }
        .environment(\.layoutDirection, layoutDirection)
    }
}

// MARK: - Accessibility Focus Management

/// A view modifier that requests accessibility focus when a condition becomes true.
struct AccessibilityFocusOnAppear: ViewModifier {
    @AccessibilityFocusState private var isFocused: Bool
    let delay: TimeInterval

    init(delay: TimeInterval = 0.5) {
        self.delay = delay
    }

    func body(content: Content) -> some View {
        content
            .accessibilityFocused($isFocused)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    isFocused = true
                }
            }
    }
}

extension View {
    /// Request VoiceOver focus when this view appears.
    func accessibilityFocusOnAppear(delay: TimeInterval = 0.5) -> some View {
        modifier(AccessibilityFocusOnAppear(delay: delay))
    }
}

// MARK: - Localization Architecture

/// Namespace for booth-specific localized strings.
/// All strings use Swift's String(localized:comment:) for Xcode string catalog support.
///
/// Usage in views:
///   Text(BoothStrings.attractTitle)
///
/// The strings are automatically extracted into Localizable.xcstrings by Xcode.
/// Translators can work with the string catalog directly.
public enum BoothStrings {
    public static let attractTitle = String(localized: "Tap to Start", comment: "Attract screen call-to-action")
    public static let modeSelectTitle = String(localized: "Choose Your Mode", comment: "Mode selection screen title")
    public static let countdownCancel = String(localized: "Cancel", comment: "Cancel countdown button")
    public static let reviewRetake = String(localized: "Retake", comment: "Retake photo button")
    public static let reviewKeep = String(localized: "Keep", comment: "Keep photo button")
    public static let reviewKeepAll = String(localized: "Keep All", comment: "Keep all photos button")
    public static let shareTitle = String(localized: "Share Your Photos", comment: "Sharing screen title")
    public static let shareSkip = String(localized: "Skip", comment: "Skip sharing button")
    public static let thankYouTitle = String(localized: "Thank You!", comment: "Thank you screen title")
    public static let thankYouSubtitle = String(localized: "Enjoy your photos!", comment: "Thank you screen subtitle")
    public static let lowBatteryWarning = String(localized: "Low Battery", comment: "Battery warning label")
    public static let thermalWarning = String(localized: "Device Overheating", comment: "Thermal warning label")
    public static let emailPlaceholder = String(localized: "your@email.com", comment: "Email input placeholder")
    public static let phonePlaceholder = String(localized: "(555) 123-4567", comment: "Phone input placeholder")
    public static let sendButton = String(localized: "Send", comment: "Send sharing button")
    public static let printButton = String(localized: "Print Now", comment: "Print button")
    public static let scanQRCode = String(localized: "Scan to Download", comment: "QR code instruction")
    public static let photoCountFormat = String(localized: "Photo %d of %d", comment: "Photo counter (current, total)")
}

// MARK: - Language Picker

/// In-app language picker for multi-language kiosk deployments.
struct LanguagePicker: View {
    let availableLanguages: [String]
    @Binding var selectedLanguage: String

    var body: some View {
        HStack(spacing: 12) {
            ForEach(availableLanguages, id: \.self) { code in
                Button {
                    selectedLanguage = code
                    HapticEngine.shared.selectionChanged()
                } label: {
                    Text(displayName(for: code))
                        .font(.callout.weight(selectedLanguage == code ? .bold : .regular))
                        .foregroundStyle(selectedLanguage == code ? .white : .white.opacity(0.5))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(selectedLanguage == code ? Color.white.opacity(0.2) : Color.clear)
                        )
                }
                .accessibilityLabel(Text(displayName(for: code)))
                .accessibilityAddTraits(selectedLanguage == code ? .isSelected : [])
            }
        }
    }

    private func displayName(for code: String) -> String {
        let locale = Locale(identifier: code)
        return locale.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }
}
