// ModeSelectScreen.swift
// Grid/carousel of capture modes with animated previews and disabled states.

import SwiftUI

/// Displays available capture modes for the user to choose from.
/// Disabled modes are shown grayed out. Long-press reveals a description tooltip.
public struct ModeSelectScreen: View {

    let session: BoothSession

    @State private var hoveredMode: CaptureMode?
    @State private var showDescription: Bool = false
    @State private var descriptionMode: CaptureMode?
    @State private var selectedAnimation: Bool = false

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 24)
    ]

    public init(session: BoothSession) {
        self.session = session
    }

    public var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    session.config.primaryColor.opacity(0.8),
                    session.config.secondaryColor.opacity(0.6),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 40) {
                // Header
                header
                    .padding(.top, 80)

                // Mode grid
                LazyVGrid(columns: columns, spacing: 28) {
                    ForEach(CaptureMode.allCases) { mode in
                        ModeCard(
                            mode: mode,
                            isEnabled: session.config.enabledModes.contains(mode),
                            isSelected: session.selectedMode == mode
                        )
                        .onTapGesture {
                            selectMode(mode)
                        }
                        .onLongPressGesture(minimumDuration: 0.5) {
                            showDescriptionFor(mode)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text(mode.displayName))
                        .accessibilityHint(
                            session.config.enabledModes.contains(mode)
                                ? Text("Double tap to select \(mode.displayName) mode")
                                : Text("\(mode.displayName) mode is not available")
                        )
                        .accessibilityAddTraits(
                            session.config.enabledModes.contains(mode) ? .isButton : .isStaticText
                        )
                    }
                }
                .padding(.horizontal, 40)

                Spacer()

                // Start button
                Button {
                    session.navigate(to: .countdown)
                } label: {
                    Label("Start", systemImage: "camera.fill")
                }
                .buttonStyle(BoothPrimaryButtonStyle(color: session.config.primaryColor))
                .padding(.bottom, 20)

                // Back button
                Button("Back") {
                    session.navigate(to: .attract)
                }
                .buttonStyle(BoothSecondaryButtonStyle())
                .padding(.bottom, 60)
            }

            // Description tooltip overlay
            if showDescription, let mode = descriptionMode {
                descriptionOverlay(for: mode)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Text("Choose Your Mode")
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Select how you want to capture")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: - Mode Selection

    private func selectMode(_ mode: CaptureMode) {
        guard session.config.enabledModes.contains(mode) else {
            HapticEngine.shared.error()
            return
        }
        HapticEngine.shared.buttonPress()
        SoundManager.shared.play(.tap)
        session.selectedMode = mode
    }

    private func showDescriptionFor(_ mode: CaptureMode) {
        descriptionMode = mode
        HapticEngine.shared.selectionChanged()
        withAnimation(.spring(response: 0.3)) {
            showDescription = true
        }
    }

    // MARK: - Description Overlay

    private func descriptionOverlay(for mode: CaptureMode) -> some View {
        VStack(spacing: 16) {
            Image(systemName: mode.systemIcon)
                .font(.system(size: 40))
                .foregroundStyle(session.config.primaryColor)

            Text(mode.displayName)
                .font(.title2.bold())
                .foregroundStyle(.white)

            Text(mode.description)
                .font(.body)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(maxWidth: 360)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        .transition(.scale.combined(with: .opacity))
        .onTapGesture {
            withAnimation(.spring(response: 0.3)) {
                showDescription = false
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(mode.displayName): \(mode.description)"))
        .accessibilityAddTraits(.isModal)
    }
}

// MARK: - Mode Card

/// A single mode option card with an animated icon and selection state.
struct ModeCard: View {
    let mode: CaptureMode
    let isEnabled: Bool
    let isSelected: Bool

    @State private var iconAnimation: Bool = false

    var body: some View {
        VStack(spacing: 14) {
            // Animated icon
            ZStack {
                Circle()
                    .fill(isSelected ? Color.white : Color.white.opacity(0.15))
                    .frame(width: 100, height: 100)

                Image(systemName: mode.systemIcon)
                    .font(.system(size: 36))
                    .foregroundStyle(isSelected ? Color.black : .white)
                    .rotationEffect(.degrees(iconAnimation && isEnabled ? 5 : 0))
                    .scaleEffect(iconAnimation && isEnabled ? 1.05 : 1.0)
            }
            .shadow(
                color: isSelected ? .white.opacity(0.3) : .clear,
                radius: 12
            )

            Text(mode.displayName)
                .font(.headline)
                .foregroundStyle(isEnabled ? .white : .white.opacity(0.4))

            if !isEnabled {
                Text("Unavailable")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    isSelected
                        ? Color.white.opacity(0.15)
                        : Color.white.opacity(0.05)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.white.opacity(0.5) : Color.clear,
                            lineWidth: 2
                        )
                )
        )
        .opacity(isEnabled ? 1.0 : 0.4)
        .scaleEffect(isSelected ? 1.05 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        .onAppear {
            guard isEnabled else { return }
            withAnimation(
                .easeInOut(duration: 2.0)
                    .repeatForever(autoreverses: true)
                    .delay(Double.random(in: 0...1))
            ) {
                iconAnimation = true
            }
        }
    }
}

#if DEBUG
#Preview("Mode Select Screen") {
    let session = BoothSession()
    ModeSelectScreen(session: session)
}
#endif
