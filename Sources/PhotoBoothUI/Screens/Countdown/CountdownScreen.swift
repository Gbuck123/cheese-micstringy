// CountdownScreen.swift
// Full-screen animated countdown timer with shutter sound and flash effect.

import SwiftUI
import AudioToolbox

/// Displays a large animated countdown (3, 2, 1) with progressive scale/opacity
/// transitions, shutter sound at zero, and a flash effect on capture.
public struct CountdownScreen: View {

    let session: BoothSession

    @State private var currentNumber: Int
    @State private var numberScale: CGFloat = 0.3
    @State private var numberOpacity: Double = 0
    @State private var showFlash: Bool = false
    @State private var countdownActive: Bool = true
    @State private var timer: Timer?

    public init(session: BoothSession) {
        self.session = session
        self._currentNumber = State(initialValue: session.config.countdownDuration)
    }

    public var body: some View {
        ZStack {
            // Background: camera preview would be here in production.
            // For now, a dark background with the shot count indicator.
            Color.black.ignoresSafeArea()

            // Shot progress indicator (top)
            VStack {
                shotProgressBar
                    .padding(.top, 60)
                Spacer()
            }

            // Countdown number
            if countdownActive {
                Text("\(currentNumber)")
                    .font(.system(size: 220, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .white.opacity(0.3), radius: 20)
                    .scaleEffect(numberScale)
                    .opacity(numberOpacity)
                    .id(currentNumber) // Force view recreation on number change
                    .accessibilityLabel(Text("\(currentNumber)"))
            }

            // Progress ring around the number
            CountdownRing(
                total: session.config.countdownDuration,
                remaining: currentNumber
            )

            // Flash effect overlay
            Color.white
                .ignoresSafeArea()
                .opacity(showFlash ? 1 : 0)
                .animation(.easeOut(duration: 0.3), value: showFlash)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            // Cancel button (bottom)
            VStack {
                Spacer()
                Button("Cancel") {
                    cancelCountdown()
                    session.navigate(to: .attract)
                }
                .buttonStyle(BoothSecondaryButtonStyle())
                .padding(.bottom, 60)
            }
        }
        .onAppear {
            startCountdown()
        }
        .onDisappear {
            cancelCountdown()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Countdown to capture"))
    }

    // MARK: - Shot Progress

    private var shotProgressBar: some View {
        HStack(spacing: 12) {
            ForEach(0..<session.config.multiShotCount, id: \.self) { index in
                Circle()
                    .fill(index < session.capturedImages.count ? Color.green : Color.white.opacity(0.3))
                    .frame(width: 16, height: 16)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white, lineWidth: index == session.capturedImages.count ? 2 : 0)
                    )
                    .accessibilityLabel(Text("Shot \(index + 1): \(index < session.capturedImages.count ? "captured" : "pending")"))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
        )
    }

    // MARK: - Countdown Logic

    private func startCountdown() {
        currentNumber = session.config.countdownDuration
        countdownActive = true
        animateNumber()

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [self] _ in
            guard countdownActive else { return }

            if currentNumber > 1 {
                currentNumber -= 1
                animateNumber()
                HapticEngine.shared.countdownTick(step: currentNumber)
                SoundManager.shared.play(.countdownTick)
            } else {
                // Countdown complete - capture!
                countdownActive = false
                timer?.invalidate()
                timer = nil
                triggerCapture()
            }
        }
    }

    private func animateNumber() {
        // Reset
        numberScale = 0.3
        numberOpacity = 0

        // Animate in
        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
            numberScale = 1.0
            numberOpacity = 1.0
        }

        // Fade out near the end of the second
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(.easeIn(duration: 0.25)) {
                numberOpacity = 0.3
                numberScale = 0.85
            }
        }
    }

    private func triggerCapture() {
        // Play shutter sound
        if session.config.shutterSoundEnabled {
            SoundManager.shared.play(.shutter)
        }

        // Shutter haptic
        HapticEngine.shared.captureShutter()

        // Flash effect
        if session.config.flashEffectEnabled {
            showFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                showFlash = false
            }
        }

        // Navigate to capture (camera pipeline takes the actual photo)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            session.navigate(to: .capture)
        }
    }

    private func cancelCountdown() {
        countdownActive = false
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Countdown Ring

/// A circular progress ring showing countdown progress.
struct CountdownRing: View {
    let total: Int
    let remaining: Int

    @State private var progress: CGFloat = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: progress)
            .stroke(
                AngularGradient(
                    gradient: Gradient(colors: [.blue, .purple, .blue]),
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 8, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
            .frame(width: 300, height: 300)
            .onChange(of: remaining) { _, newValue in
                withAnimation(.linear(duration: 0.9)) {
                    progress = 1.0 - CGFloat(newValue - 1) / CGFloat(total)
                }
            }
            .onAppear {
                progress = 0
            }
            .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Countdown Screen") {
    CountdownScreen(session: BoothSession())
}
#endif
