// LoopingVideoPlayer.swift
// AVPlayerLooper-backed video player for the attract screen.

import SwiftUI
import AVFoundation

/// A SwiftUI view that plays a video in a seamless loop using AVPlayerLooper.
/// Uses AVPlayerLayer via UIViewRepresentable for optimal performance (no VideoPlayer overhead).
struct LoopingVideoPlayer: UIViewRepresentable {

    let url: URL

    func makeUIView(context: Context) -> LoopingVideoPlayerUIView {
        let view = LoopingVideoPlayerUIView()
        view.configure(url: url)
        return view
    }

    func updateUIView(_ uiView: LoopingVideoPlayerUIView, context: Context) {
        // URL changes are rare for attract screens, but handle them.
        if uiView.currentURL != url {
            uiView.configure(url: url)
        }
    }

    static func dismantleUIView(_ uiView: LoopingVideoPlayerUIView, coordinator: ()) {
        uiView.cleanup()
    }
}

// MARK: - UIView Implementation

/// The underlying UIView that hosts the AVPlayerLayer and AVPlayerLooper.
final class LoopingVideoPlayerUIView: UIView {

    private var player: AVQueuePlayer?
    private var playerLayer: AVPlayerLayer?
    private var looper: AVPlayerLooper?
    private(set) var currentURL: URL?

    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    private var avPlayerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    func configure(url: URL) {
        // Clean up existing player if re-configuring.
        cleanup()
        currentURL = url

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)

        let queuePlayer = AVQueuePlayer(playerItem: item)
        queuePlayer.isMuted = true // Attract videos are typically silent or have ambient audio.

        // AVPlayerLooper seamlessly loops the item.
        let playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: item)

        self.player = queuePlayer
        self.looper = playerLooper

        avPlayerLayer.player = queuePlayer
        avPlayerLayer.videoGravity = .resizeAspectFill

        queuePlayer.play()
    }

    func cleanup() {
        player?.pause()
        player?.removeAllItems()
        looper?.disableLooping()
        looper = nil
        player = nil
        currentURL = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        avPlayerLayer.frame = bounds
    }

    deinit {
        cleanup()
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Looping Video Player") {
    // In preview, fall back to a colored rectangle since we won't have a real video URL.
    ZStack {
        Color.black
        Text("Video Player Placeholder")
            .foregroundStyle(.white)
    }
    .ignoresSafeArea()
}
#endif
