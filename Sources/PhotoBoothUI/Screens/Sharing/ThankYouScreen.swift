// ThankYouScreen.swift
// Thank-you screen with auto-return to attract screen after configurable delay.

import SwiftUI

/// Shown after the user completes sharing. Displays a thank-you message
/// and automatically returns to the attract screen after a timeout.
public struct ThankYouScreen: View {

    let session: BoothSession

    @State private var checkmarkScale: CGFloat = 0
    @State private var checkmarkOpacity: Double = 0
    @State private var textOpacity: Double = 0
    @State private var confettiVisible: Bool = false

    public init(session: BoothSession) {
        self.session = session
    }

    public var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [
                    session.config.primaryColor.opacity(0.5),
                    session.config.secondaryColor.opacity(0.3),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Confetti particles
            if confettiVisible {
                ConfettiView()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 32) {
                Spacer()

                // Animated checkmark
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.2))
                        .frame(width: 140, height: 140)
                        .scaleEffect(checkmarkScale)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 100))
                        .foregroundStyle(.green)
                        .scaleEffect(checkmarkScale)
                        .opacity(checkmarkOpacity)
                }

                VStack(spacing: 12) {
                    Text("Thank You!")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .opacity(textOpacity)

                    Text("Enjoy your \(session.config.eventName) photos!")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.8))
                        .opacity(textOpacity)
                }

                Spacer()

                // Auto-return timer
                AutoAdvanceTimerView(duration: session.config.thankYouTimeout) {
                    returnToAttract()
                }
                .padding(.bottom, 20)

                Text("Returning to start...")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, 60)
            }
        }
        .onAppear {
            playEntryAnimation()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Tap to immediately return.
            returnToAttract()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Thank you for using the photo booth. Tap anywhere to start over."))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Animation

    private func playEntryAnimation() {
        HapticEngine.shared.success()
        SoundManager.shared.play(.success)

        withAnimation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.1)) {
            checkmarkScale = 1.0
            checkmarkOpacity = 1.0
        }
        withAnimation(.easeOut(duration: 0.6).delay(0.4)) {
            textOpacity = 1.0
        }
        withAnimation(.easeIn(duration: 0.3).delay(0.6)) {
            confettiVisible = true
        }
    }

    private func returnToAttract() {
        session.reset()
    }
}

// MARK: - Simple Confetti View

/// A lightweight confetti particle animation for the thank-you screen.
struct ConfettiView: View {
    @State private var particles: [ConfettiParticle] = []

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(particles) { particle in
                    Circle()
                        .fill(particle.color)
                        .frame(width: particle.size, height: particle.size)
                        .position(particle.position)
                        .opacity(particle.opacity)
                }
            }
            .onAppear {
                generateParticles(in: geometry.size)
                animateParticles(in: geometry.size)
            }
        }
    }

    private func generateParticles(in size: CGSize) {
        let colors: [Color] = [.red, .blue, .green, .yellow, .purple, .orange, .pink, .cyan]
        particles = (0..<40).map { _ in
            ConfettiParticle(
                color: colors.randomElement() ?? .white,
                size: CGFloat.random(in: 6...14),
                position: CGPoint(
                    x: CGFloat.random(in: 0...size.width),
                    y: -20
                ),
                targetY: size.height + 20,
                opacity: 1.0
            )
        }
    }

    private func animateParticles(in size: CGSize) {
        for i in particles.indices {
            let delay = Double.random(in: 0...1.5)
            let duration = Double.random(in: 2.0...4.0)

            withAnimation(.easeIn(duration: duration).delay(delay)) {
                particles[i].position.y = particles[i].targetY
                particles[i].position.x += CGFloat.random(in: -80...80)
                particles[i].opacity = 0
            }
        }
    }
}

struct ConfettiParticle: Identifiable {
    let id = UUID()
    let color: Color
    let size: CGFloat
    var position: CGPoint
    let targetY: CGFloat
    var opacity: Double
}

#if DEBUG
#Preview("Thank You Screen") {
    ThankYouScreen(session: BoothSession())
}
#endif
