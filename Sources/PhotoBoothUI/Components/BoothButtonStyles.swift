// BoothButtonStyles.swift
// Reusable button styles for the photo booth UI.

import SwiftUI

// MARK: - Primary Button

/// Large, prominent button used for primary actions ("Keep", "Start", etc.).
public struct BoothPrimaryButtonStyle: ButtonStyle {
    var color: Color = .blue

    public init(color: Color = .blue) {
        self.color = color
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 48)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(color)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    HapticEngine.shared.buttonPress()
                }
            }
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Secondary Button

/// Outlined button for secondary actions ("Retake", "Cancel", etc.).
public struct BoothSecondaryButtonStyle: ButtonStyle {
    var color: Color = .white

    public init(color: Color = .white) {
        self.color = color
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 40)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(color.opacity(0.6), lineWidth: 2)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    HapticEngine.shared.buttonPress()
                }
            }
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Icon Button

/// Circular icon button used in sharing options, mode selection, etc.
public struct BoothIconButtonStyle: ButtonStyle {
    var size: CGFloat = 80
    var backgroundColor: Color = .blue
    var foregroundColor: Color = .white

    public init(size: CGFloat = 80, backgroundColor: Color = .blue, foregroundColor: Color = .white) {
        self.size = size
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.4))
            .foregroundStyle(foregroundColor)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(backgroundColor)
                    .shadow(color: backgroundColor.opacity(0.4), radius: configuration.isPressed ? 4 : 8, y: 4)
            )
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    HapticEngine.shared.buttonPress()
                }
            }
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Auto-Advance Timer View

/// A circular progress timer that auto-advances after a configured duration.
struct AutoAdvanceTimerView: View {
    let duration: TimeInterval
    let onComplete: () -> Void

    @State private var progress: CGFloat = 0
    @State private var remaining: Int

    init(duration: TimeInterval, onComplete: @escaping () -> Void) {
        self.duration = duration
        self.onComplete = onComplete
        self._remaining = State(initialValue: Int(duration))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.2), lineWidth: 4)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Text("\(remaining)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(width: 44, height: 44)
        .onAppear {
            withAnimation(.linear(duration: duration)) {
                progress = 1.0
            }
            startCountdown()
        }
        .accessibilityLabel(Text("\(remaining) seconds remaining"))
    }

    private func startCountdown() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            remaining -= 1
            if remaining <= 0 {
                timer.invalidate()
                onComplete()
            }
        }
    }
}
