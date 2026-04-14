// AttractScreen.swift
// Full-screen attract loop with video playback, idle dimming, and burn-in prevention.

import SwiftUI
import AVFoundation
import Combine

/// The attract screen is the idle state of the booth. It plays a looping video
/// (or shows a static image), dims after inactivity, and subtly animates to
/// prevent OLED burn-in. Tapping anywhere begins the session.
public struct AttractScreen: View {

    let session: BoothSession

    @State private var viewModel: AttractViewModel
    @State private var rippleOrigin: CGPoint = .zero
    @State private var showRipple: Bool = false

    public init(session: BoothSession) {
        self.session = session
        self._viewModel = State(initialValue: AttractViewModel(config: session.config))
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Layer 1: Video or static image background
                attractBackground
                    .ignoresSafeArea()

                // Layer 2: Dim overlay
                Color.black
                    .opacity(viewModel.isDimmed ? Double(1.0 - session.config.dimmedBrightness) : 0)
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 1.5), value: viewModel.isDimmed)
                    .allowsHitTesting(false)

                // Layer 3: Call-to-action overlay with burn-in prevention
                callToActionOverlay
                    .offset(viewModel.burnInOffset)
                    .animation(.easeInOut(duration: 8).repeatForever(autoreverses: true), value: viewModel.burnInOffset)

                // Layer 4: Ripple animation on tap
                if showRipple {
                    RippleEffect(origin: rippleOrigin)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle()) // Make entire area tappable
            .onTapGesture { location in
                rippleOrigin = location
                handleTap()
            }
            .onAppear {
                viewModel.startIdleTimer()
                viewModel.startBurnInPrevention()
            }
            .onDisappear {
                viewModel.stopAll()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Welcome screen. Tap anywhere to start."))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Background

    @ViewBuilder
    private var attractBackground: some View {
        if let videoURL = session.config.attractVideoURL {
            LoopingVideoPlayer(url: videoURL)
                .ignoresSafeArea()
        } else {
            Image(session.config.attractImageName)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .ignoresSafeArea()
        }
    }

    // MARK: - Call to Action

    private var callToActionOverlay: some View {
        VStack(spacing: 20) {
            Spacer()

            Text(session.config.eventName)
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)

            Text("Tap anywhere to start")
                .font(.title2.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                )
                .pulsingOpacity()

            Spacer()
                .frame(height: 100)
        }
    }

    // MARK: - Tap Handling

    private func handleTap() {
        // Wake from dim
        if viewModel.isDimmed {
            viewModel.isDimmed = false
            viewModel.resetIdleTimer()
            return
        }

        // Show ripple and navigate
        showRipple = true
        HapticEngine.shared.buttonPress()
        SoundManager.shared.play(.tap)

        // Brief delay for the ripple to play before transitioning
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            session.navigate(to: .modeSelect)
        }
    }
}

// MARK: - Attract View Model

@Observable
final class AttractViewModel {

    var isDimmed: Bool = false
    var burnInOffset: CGSize = .zero

    private let config: BoothConfiguration
    private var idleTimer: Timer?
    private var burnInTimer: Timer?

    init(config: BoothConfiguration) {
        self.config = config
    }

    func startIdleTimer() {
        resetIdleTimer()
    }

    func resetIdleTimer() {
        idleTimer?.invalidate()
        isDimmed = false
        idleTimer = Timer.scheduledTimer(withTimeInterval: config.idleDimTimeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.isDimmed = true
        }
    }

    func startBurnInPrevention() {
        // Subtle random offset every 8 seconds to prevent OLED burn-in.
        animateBurnIn()
        burnInTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            self?.animateBurnIn()
        }
    }

    private func animateBurnIn() {
        let maxShift: CGFloat = 6
        burnInOffset = CGSize(
            width: CGFloat.random(in: -maxShift...maxShift),
            height: CGFloat.random(in: -maxShift...maxShift)
        )
    }

    func stopAll() {
        idleTimer?.invalidate()
        idleTimer = nil
        burnInTimer?.invalidate()
        burnInTimer = nil
    }
}

// MARK: - Pulsing Opacity Modifier

extension View {
    func pulsingOpacity(min: Double = 0.6, max: Double = 1.0, duration: Double = 2.0) -> some View {
        modifier(PulsingOpacityModifier(minOpacity: min, maxOpacity: max, duration: duration))
    }
}

struct PulsingOpacityModifier: ViewModifier {
    let minOpacity: Double
    let maxOpacity: Double
    let duration: Double

    @State private var isAnimating = false

    func body(content: Content) -> some View {
        content
            .opacity(isAnimating ? maxOpacity : minOpacity)
            .onAppear {
                withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
                    isAnimating = true
                }
            }
    }
}
