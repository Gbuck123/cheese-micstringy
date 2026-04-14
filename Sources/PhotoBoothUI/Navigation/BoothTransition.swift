// BoothTransition.swift
// Custom full-screen transitions for navigating between booth screens.

import SwiftUI

// MARK: - Transition Types

/// The type of transition to use between screens.
public enum BoothTransitionStyle: Sendable {
    case crossDissolve
    case slideLeft
    case slideRight
    case slideUp
    case slideDown
    case zoom
    case zoomOut
    case none
}

// MARK: - Transition Resolver

/// Determines the appropriate transition style based on screen navigation.
public struct BoothTransitionResolver {
    public static func transition(from: BoothScreen?, to: BoothScreen) -> BoothTransitionStyle {
        guard let from else { return .crossDissolve }

        switch (from, to) {
        case (.attract, .modeSelect): return .slideUp
        case (.modeSelect, .countdown): return .zoom
        case (.countdown, .capture): return .crossDissolve
        case (.capture, .review): return .slideLeft
        case (.review, .sharing): return .slideLeft
        case (.review, .countdown): return .slideRight // Retake
        case (.sharing, .thankYou): return .crossDissolve
        case (.thankYou, .attract): return .crossDissolve
        case (_, .attract): return .zoomOut // Any reset goes to attract
        case (.modeSelect, .attract): return .slideDown
        default: return .crossDissolve
        }
    }
}

// MARK: - Cross Dissolve

/// A symmetric modifier for cross-dissolve transitions.
struct CrossDissolveModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isActive ? 1 : 0)
    }
}

// MARK: - Slide Modifier

/// Directional slide transition.
struct SlideTransitionModifier: ViewModifier {
    let isActive: Bool
    let edge: Edge

    func body(content: Content) -> some View {
        content
            .offset(offset)
            .opacity(isActive ? 1 : 0)
    }

    private var offset: CGSize {
        guard !isActive else { return .zero }
        switch edge {
        case .leading: return CGSize(width: -UIScreen.main.bounds.width, height: 0)
        case .trailing: return CGSize(width: UIScreen.main.bounds.width, height: 0)
        case .top: return CGSize(width: 0, height: -UIScreen.main.bounds.height)
        case .bottom: return CGSize(width: 0, height: UIScreen.main.bounds.height)
        }
    }
}

// MARK: - Zoom Modifier

/// Zoom in/out transition.
struct ZoomTransitionModifier: ViewModifier {
    let isActive: Bool
    let zoomIn: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(isActive ? 1.0 : (zoomIn ? 0.3 : 1.8))
            .opacity(isActive ? 1 : 0)
    }
}

// MARK: - AnyTransition Extensions

extension AnyTransition {
    static var boothCrossDissolve: AnyTransition {
        .modifier(
            active: CrossDissolveModifier(isActive: false),
            identity: CrossDissolveModifier(isActive: true)
        )
    }

    static func boothSlide(edge: Edge) -> AnyTransition {
        .modifier(
            active: SlideTransitionModifier(isActive: false, edge: edge),
            identity: SlideTransitionModifier(isActive: true, edge: edge)
        )
    }

    static var boothZoomIn: AnyTransition {
        .modifier(
            active: ZoomTransitionModifier(isActive: false, zoomIn: true),
            identity: ZoomTransitionModifier(isActive: true, zoomIn: true)
        )
    }

    static var boothZoomOut: AnyTransition {
        .modifier(
            active: ZoomTransitionModifier(isActive: false, zoomIn: false),
            identity: ZoomTransitionModifier(isActive: true, zoomIn: false)
        )
    }
}

// MARK: - Transition for Style

extension AnyTransition {
    /// Convert a `BoothTransitionStyle` to a SwiftUI `AnyTransition`.
    static func booth(style: BoothTransitionStyle) -> AnyTransition {
        switch style {
        case .crossDissolve: return .boothCrossDissolve
        case .slideLeft: return .boothSlide(edge: .trailing)
        case .slideRight: return .boothSlide(edge: .leading)
        case .slideUp: return .boothSlide(edge: .bottom)
        case .slideDown: return .boothSlide(edge: .top)
        case .zoom: return .boothZoomIn
        case .zoomOut: return .boothZoomOut
        case .none: return .identity
        }
    }
}
