// RippleEffect.swift
// Animated ripple that expands from the tap point on the attract screen.

import SwiftUI

/// An expanding circular ripple animation that originates from a tap location.
struct RippleEffect: View {
    let origin: CGPoint

    @State private var scale: CGFloat = 0
    @State private var opacity: Double = 0.6

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(colors: [
                        .white.opacity(0.4),
                        .white.opacity(0.15),
                        .clear
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: 200
                )
            )
            .frame(width: 400, height: 400)
            .scaleEffect(scale)
            .opacity(opacity)
            .position(origin)
            .onAppear {
                withAnimation(.easeOut(duration: 0.7)) {
                    scale = 4.0
                    opacity = 0
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Multi-Ring Ripple

/// A more elaborate ripple with multiple concentric rings.
struct MultiRingRipple: View {
    let origin: CGPoint
    let ringCount: Int = 3

    @State private var animating = false

    var body: some View {
        ZStack {
            ForEach(0..<ringCount, id: \.self) { index in
                Circle()
                    .strokeBorder(
                        Color.white.opacity(animating ? 0 : 0.3),
                        lineWidth: animating ? 1 : 3
                    )
                    .frame(width: 60, height: 60)
                    .scaleEffect(animating ? 8.0 : 0.5)
                    .animation(
                        .easeOut(duration: 1.0)
                            .delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .position(origin)
        .onAppear {
            animating = true
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Ripple Effect") {
    ZStack {
        Color.black.ignoresSafeArea()
        RippleEffect(origin: CGPoint(x: 200, y: 400))
    }
}
#endif
