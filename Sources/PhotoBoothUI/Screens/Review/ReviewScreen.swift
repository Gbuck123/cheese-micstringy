// ReviewScreen.swift
// Photo review with swipe navigation, pinch-to-zoom, retake/keep actions, and auto-advance timer.

import SwiftUI

/// Displays captured photos with template overlay, swipe navigation between
/// multi-shot captures, pinch-to-zoom, and retake/keep actions.
public struct ReviewScreen: View {

    let session: BoothSession

    @State private var currentIndex: Int = 0
    @State private var zoomScale: CGFloat = 1.0
    @State private var zoomAnchor: UnitPoint = .center
    @State private var dragOffset: CGSize = .zero
    @State private var showAutoAdvance: Bool = true

    public init(session: BoothSession) {
        self.session = session
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar with page indicator and auto-advance timer
                topBar
                    .padding(.top, 60)
                    .padding(.horizontal, 24)

                // Photo viewer with swipe
                TabView(selection: $currentIndex) {
                    ForEach(Array(session.capturedImages.enumerated()), id: \.offset) { index, image in
                        ZoomableImageView(
                            image: image,
                            zoomScale: $zoomScale,
                            templateOverlayName: session.config.templateOverlayName,
                            isZoomEnabled: session.config.pinchToZoomEnabled
                        )
                        .tag(index)
                        .accessibilityLabel(Text("Photo \(index + 1) of \(session.capturedImages.count)"))
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .onChange(of: currentIndex) { _, newValue in
                    session.reviewIndex = newValue
                    HapticEngine.shared.selectionChanged()
                }

                // Action buttons
                actionButtons
                    .padding(.bottom, 60)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Photo review"))
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            // Page indicator
            HStack(spacing: 8) {
                ForEach(0..<session.capturedImages.count, id: \.self) { index in
                    Circle()
                        .fill(index == currentIndex ? Color.white : Color.white.opacity(0.3))
                        .frame(width: 10, height: 10)
                        .scaleEffect(index == currentIndex ? 1.2 : 1.0)
                        .animation(.spring(response: 0.3), value: currentIndex)
                }
            }
            .accessibilityLabel(Text("Photo \(currentIndex + 1) of \(session.capturedImages.count)"))

            Spacer()

            // Auto-advance timer
            if showAutoAdvance {
                AutoAdvanceTimerView(duration: session.config.reviewAutoAdvanceTimeout) {
                    autoKeep()
                }
            }
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 40) {
            // Retake
            Button {
                retakeCurrentPhoto()
            } label: {
                Label("Retake", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(BoothSecondaryButtonStyle())
            .accessibilityHint(Text("Retake photo \(currentIndex + 1)"))

            // Keep / Continue
            Button {
                keepPhotos()
            } label: {
                Label(
                    session.capturedImages.count == 1 ? "Keep" : "Keep All",
                    systemImage: "checkmark"
                )
            }
            .buttonStyle(BoothPrimaryButtonStyle(color: .green))
            .accessibilityHint(Text("Accept photos and continue to sharing"))
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Actions

    private func retakeCurrentPhoto() {
        HapticEngine.shared.buttonPress()
        session.retakeCurrentImage()

        if session.capturedImages.isEmpty {
            // All photos retaken, go back to countdown.
            session.navigate(to: .countdown)
        } else {
            // Adjust index.
            currentIndex = min(currentIndex, session.capturedImages.count - 1)
        }
    }

    private func keepPhotos() {
        HapticEngine.shared.success()
        SoundManager.shared.play(.success)
        session.navigate(to: .sharing)
    }

    private func autoKeep() {
        // Auto-advance: keep photos after timeout.
        HapticEngine.shared.success()
        session.navigate(to: .sharing)
    }
}

// MARK: - Zoomable Image View

/// A photo view with pinch-to-zoom and template overlay support.
struct ZoomableImageView: View {
    let image: UIImage
    @Binding var zoomScale: CGFloat
    let templateOverlayName: String?
    let isZoomEnabled: Bool

    @State private var steadyStateScale: CGFloat = 1.0
    @GestureState private var gestureScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @GestureState private var gestureOffset: CGSize = .zero

    private var effectiveScale: CGFloat {
        steadyStateScale * gestureScale
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Photo
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Template overlay
                if let overlayName = templateOverlayName {
                    Image(overlayName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .scaleEffect(effectiveScale)
            .offset(
                x: offset.width + gestureOffset.width,
                y: offset.height + gestureOffset.height
            )
            .gesture(zoomGesture)
            .gesture(panGesture)
            .onTapGesture(count: 2) {
                // Double-tap to reset zoom.
                withAnimation(.spring(response: 0.3)) {
                    steadyStateScale = 1.0
                    offset = .zero
                }
            }
            .clipped()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Gestures

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .updating($gestureScale) { value, state, _ in
                guard isZoomEnabled else { return }
                state = value
            }
            .onEnded { value in
                guard isZoomEnabled else { return }
                steadyStateScale *= value
                steadyStateScale = min(max(steadyStateScale, 0.5), 5.0)
                zoomScale = steadyStateScale
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .updating($gestureOffset) { value, state, _ in
                guard steadyStateScale > 1.0 else { return }
                state = value.translation
            }
            .onEnded { value in
                guard steadyStateScale > 1.0 else { return }
                offset.width += value.translation.width
                offset.height += value.translation.height
            }
    }
}

#if DEBUG
#Preview("Review Screen") {
    let session = BoothSession()
    // Add placeholder images.
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 600))
    let img = renderer.image { ctx in
        UIColor.systemBlue.setFill()
        ctx.fill(CGRect(origin: .zero, size: CGSize(width: 400, height: 600)))
    }
    session.addCapturedImage(img)
    session.addCapturedImage(img)
    return ReviewScreen(session: session)
}
#endif
