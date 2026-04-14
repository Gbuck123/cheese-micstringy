// BoothNavigationContainer.swift
// Root container view that manages animated transitions between booth screens.

import SwiftUI

/// The root container that renders the current booth screen with animated transitions.
/// This replaces NavigationStack with a custom state-machine-driven approach
/// suitable for a kiosk where standard navigation UX is undesirable.
public struct BoothNavigationContainer: View {

    @Bindable var session: BoothSession

    @State private var transitionStyle: BoothTransitionStyle = .crossDissolve

    public init(session: BoothSession) {
        self.session = session
    }

    public var body: some View {
        ZStack {
            // Use an ID-keyed container so SwiftUI treats each screen as a
            // unique view, enabling insertion/removal transitions.
            screenView(for: session.currentScreen)
                .id(session.currentScreen)
                .transition(
                    .asymmetric(
                        insertion: .booth(style: transitionStyle),
                        removal: .booth(style: removalStyle(for: transitionStyle))
                    )
                )
        }
        .animation(.easeInOut(duration: 0.5), value: session.currentScreen)
        .onChange(of: session.currentScreen) { oldValue, newValue in
            transitionStyle = BoothTransitionResolver.transition(from: oldValue, to: newValue)
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    @ViewBuilder
    private func screenView(for screen: BoothScreen) -> some View {
        switch screen {
        case .attract:
            AttractScreen(session: session)
        case .modeSelect:
            ModeSelectScreen(session: session)
        case .countdown:
            CountdownScreen(session: session)
        case .capture:
            // Capture is typically a live camera view; placeholder here.
            CaptureScreenPlaceholder(session: session)
        case .review:
            ReviewScreen(session: session)
        case .sharing:
            SharingScreen(session: session)
        case .thankYou:
            ThankYouScreen(session: session)
        }
    }

    /// The removal transition should be the "reverse" of the insertion.
    private func removalStyle(for insertion: BoothTransitionStyle) -> BoothTransitionStyle {
        switch insertion {
        case .slideLeft: return .slideRight
        case .slideRight: return .slideLeft
        case .slideUp: return .slideDown
        case .slideDown: return .slideUp
        case .zoom: return .zoomOut
        case .zoomOut: return .zoom
        default: return insertion
        }
    }
}

// MARK: - Capture Screen Placeholder

/// Placeholder for the live camera capture screen. In production, this would
/// host the camera preview via AVCaptureVideoPreviewLayer or a Metal view.
struct CaptureScreenPlaceholder: View {
    let session: BoothSession

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 80))
                    .foregroundStyle(.white)

                Text("Live Camera Preview")
                    .font(.title)
                    .foregroundStyle(.white)

                Text("Camera feed renders here via Metal/AVFoundation")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))

                Button("Simulate Capture") {
                    // In production, this would be triggered by the capture pipeline.
                    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1080, height: 1920))
                    let placeholder = renderer.image { ctx in
                        UIColor.darkGray.setFill()
                        ctx.fill(CGRect(origin: .zero, size: CGSize(width: 1080, height: 1920)))
                        let attrs: [NSAttributedString.Key: Any] = [
                            .font: UIFont.systemFont(ofSize: 60),
                            .foregroundColor: UIColor.white
                        ]
                        let text = "Photo \(session.capturedImages.count + 1)" as NSString
                        text.draw(at: CGPoint(x: 300, y: 900), withAttributes: attrs)
                    }
                    session.addCapturedImage(placeholder)

                    if session.allShotsCaptured {
                        session.navigate(to: .review)
                    } else {
                        session.navigate(to: .countdown)
                    }
                }
                .buttonStyle(BoothPrimaryButtonStyle())
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Camera capture screen"))
    }
}
