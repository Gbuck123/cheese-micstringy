// SoundManager.swift
// Preloaded sound effect manager for low-latency audio feedback.

import AVFoundation
import AudioToolbox
import os

private let logger = Logger(subsystem: "com.photobooth.ui", category: "SoundManager")

/// Defines available sound effects in the booth.
public enum BoothSound: String, CaseIterable, Sendable {
    case countdownTick = "countdown_tick"
    case countdownFinal = "countdown_final"
    case shutter = "shutter"
    case success = "success"
    case error = "error"
    case tap = "tap"
    case swoosh = "swoosh"

    /// File extension for the audio asset.
    var fileExtension: String { "wav" }
}

/// Pre-loads and plays sound effects with minimal latency using AVAudioPlayer.
/// Falls back to AudioServicesPlaySystemSound for the camera shutter.
@Observable
public final class SoundManager {

    // MARK: - Singleton

    public static let shared = SoundManager()

    // MARK: - Properties

    /// Master mute toggle.
    public var isMuted: Bool = false

    /// Volume (0.0 - 1.0).
    public var volume: Float = 1.0

    /// Pre-loaded audio players keyed by sound name.
    private var players: [BoothSound: AVAudioPlayer] = [:]

    /// Audio session configured for playback alongside other audio if needed.
    private var audioSessionConfigured = false

    // MARK: - Init

    private init() {
        configureAudioSession()
        preloadAll()
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            audioSessionConfigured = true
        } catch {
            logger.error("Failed to configure audio session: \(error.localizedDescription)")
        }
    }

    // MARK: - Preloading

    /// Pre-load all sound effects into memory for instant playback.
    public func preloadAll() {
        for sound in BoothSound.allCases {
            loadSound(sound)
        }
        logger.info("Pre-loaded \(self.players.count)/\(BoothSound.allCases.count) sound effects")
    }

    private func loadSound(_ sound: BoothSound) {
        guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: sound.fileExtension) else {
            logger.warning("Sound file not found: \(sound.rawValue).\(sound.fileExtension)")
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.volume = volume
            players[sound] = player
        } catch {
            logger.error("Failed to load sound \(sound.rawValue): \(error.localizedDescription)")
        }
    }

    // MARK: - Playback

    /// Play a pre-loaded sound effect.
    public func play(_ sound: BoothSound) {
        guard !isMuted else { return }

        // Special case: system shutter sound (plays even in silent mode on real devices).
        if sound == .shutter {
            playSystemShutter()
            return
        }

        guard let player = players[sound] else {
            logger.warning("No player for sound: \(sound.rawValue)")
            return
        }

        player.volume = volume
        if player.isPlaying {
            player.currentTime = 0 // Restart if already playing.
        }
        player.play()
    }

    /// Play the iOS system camera shutter sound (ID 1108).
    private func playSystemShutter() {
        AudioServicesPlaySystemSound(1108)
    }

    /// Play a system sound by ID (useful for standard UI feedback).
    public func playSystemSound(_ soundID: SystemSoundID) {
        guard !isMuted else { return }
        AudioServicesPlaySystemSound(soundID)
    }

    // MARK: - Cleanup

    /// Release all pre-loaded audio players.
    public func releaseAll() {
        for (_, player) in players {
            player.stop()
        }
        players.removeAll()
    }
}
