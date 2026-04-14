// BoothState.swift
// Central state machine governing the photo booth flow.
// attract -> modeSelect -> countdown -> capture -> review -> sharing -> attract

import SwiftUI

// MARK: - Booth Screen Enum

/// Every distinct screen in the photo booth kiosk flow.
public enum BoothScreen: String, CaseIterable, Sendable {
    case attract
    case modeSelect
    case countdown
    case capture
    case review
    case sharing
    case thankYou
}

// MARK: - Capture Mode

/// The capture modes available in this photo booth.
public enum CaptureMode: String, CaseIterable, Identifiable, Sendable {
    case photo
    case gif
    case boomerang
    case video
    case threeSixty

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .photo: return String(localized: "Photo", comment: "Capture mode: single photo")
        case .gif: return String(localized: "GIF", comment: "Capture mode: animated GIF")
        case .boomerang: return String(localized: "Boomerang", comment: "Capture mode: boomerang loop")
        case .video: return String(localized: "Video", comment: "Capture mode: video clip")
        case .threeSixty: return String(localized: "360°", comment: "Capture mode: 360 degree")
        }
    }

    public var description: String {
        switch self {
        case .photo: return String(localized: "Capture a single high-quality photo with filters and overlays.", comment: "Photo mode description")
        case .gif: return String(localized: "Record a short animated GIF with up to 30 frames.", comment: "GIF mode description")
        case .boomerang: return String(localized: "Create a fun back-and-forth looping animation.", comment: "Boomerang mode description")
        case .video: return String(localized: "Record a short video clip with real-time effects.", comment: "Video mode description")
        case .threeSixty: return String(localized: "Spin around for a full 360° animated capture.", comment: "360 mode description")
        }
    }

    public var systemIcon: String {
        switch self {
        case .photo: return "camera.fill"
        case .gif: return "photo.stack"
        case .boomerang: return "arrow.trianglehead.2.counterclockwise"
        case .video: return "video.fill"
        case .threeSixty: return "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }
}

// MARK: - Sharing Option

/// Available sharing methods at the sharing station.
public enum SharingOption: String, CaseIterable, Identifiable, Sendable {
    case email
    case sms
    case qrCode
    case airdrop
    case print

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .email: return String(localized: "Email", comment: "Sharing option")
        case .sms: return String(localized: "Text", comment: "Sharing option")
        case .qrCode: return String(localized: "QR Code", comment: "Sharing option")
        case .airdrop: return String(localized: "AirDrop", comment: "Sharing option")
        case .print: return String(localized: "Print", comment: "Sharing option")
        }
    }

    public var systemIcon: String {
        switch self {
        case .email: return "envelope.fill"
        case .sms: return "message.fill"
        case .qrCode: return "qrcode"
        case .airdrop: return "airplayaudio"
        case .print: return "printer.fill"
        }
    }

    public var brandColor: Color {
        switch self {
        case .email: return .blue
        case .sms: return .green
        case .qrCode: return .purple
        case .airdrop: return .cyan
        case .print: return .orange
        }
    }
}
