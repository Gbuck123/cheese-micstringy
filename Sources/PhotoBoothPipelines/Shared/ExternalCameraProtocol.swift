// ExternalCameraProtocol.swift
// Universal camera abstraction layer for the Photo Booth app.
//
// Defines a common Swift protocol that abstracts over:
//   - iPad built-in camera (AVCaptureDevice)
//   - GoPro (Open GoPro BLE + WiFi HTTP API)
//   - Canon DSLR/Mirrorless (CCAPI REST over WiFi)
//   - Sony Alpha (Camera Remote API JSON-RPC over WiFi)
//   - Nikon Z / DSLR (HTTP Server mode / PTP over WiFi)
//
// The photo booth app can switch camera sources seamlessly through this interface.

import Foundation
import CoreImage
import UIKit
import Combine

// MARK: - Camera Source Identification

/// Identifies the type/brand of external camera.
public enum CameraSourceType: String, Codable, CaseIterable, Sendable {
    case builtIn       = "builtin"
    case goPro         = "gopro"
    case canon         = "canon"
    case sony          = "sony"
    case nikon         = "nikon"
    case genericPTP    = "ptp"

    public var displayName: String {
        switch self {
        case .builtIn:    return "iPad Camera"
        case .goPro:      return "GoPro"
        case .canon:      return "Canon"
        case .sony:       return "Sony"
        case .nikon:      return "Nikon"
        case .genericPTP: return "USB Camera"
        }
    }
}

// MARK: - Camera Connection State

/// The current connection lifecycle state of an external camera.
public enum CameraConnectionState: Sendable {
    /// Camera has been discovered but not yet connected.
    case discovered
    /// Actively connecting (BLE pairing, WiFi joining, etc.).
    case connecting
    /// Connected and ready to receive commands.
    case connected
    /// Temporarily disconnected; may auto-reconnect.
    case disconnected
    /// Unrecoverable error.
    case failed(Error)

    public var isReady: Bool {
        if case .connected = self { return true }
        return false
    }
}

// MARK: - Camera Capabilities

/// Describes what a connected camera can do. Not all cameras support all features.
public struct CameraCapabilities: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Can capture still photos.
    public static let photo           = CameraCapabilities(rawValue: 1 << 0)
    /// Can record video.
    public static let video           = CameraCapabilities(rawValue: 1 << 1)
    /// Can stream a live preview / viewfinder image.
    public static let livePreview     = CameraCapabilities(rawValue: 1 << 2)
    /// Can download captured media files.
    public static let mediaDownload   = CameraCapabilities(rawValue: 1 << 3)
    /// Can change shooting settings (ISO, aperture, shutter speed, etc.).
    public static let settingsControl = CameraCapabilities(rawValue: 1 << 4)
    /// Can autofocus or manual focus remotely.
    public static let focusControl    = CameraCapabilities(rawValue: 1 << 5)
    /// Can zoom remotely.
    public static let zoomControl     = CameraCapabilities(rawValue: 1 << 6)
    /// Can provide battery level.
    public static let batteryStatus   = CameraCapabilities(rawValue: 1 << 7)
    /// Can burst / continuous shoot.
    public static let burstCapture    = CameraCapabilities(rawValue: 1 << 8)

    /// Typical DSLR/mirrorless: full control.
    public static let fullDSLR: CameraCapabilities = [
        .photo, .video, .livePreview, .mediaDownload,
        .settingsControl, .focusControl, .zoomControl, .batteryStatus
    ]

    /// GoPro: photo, video, live preview, media download, limited settings.
    public static let goProFull: CameraCapabilities = [
        .photo, .video, .livePreview, .mediaDownload,
        .settingsControl, .batteryStatus
    ]
}

// MARK: - Camera Settings

/// A generic camera setting that can be read and written.
public struct CameraSetting: Sendable {
    public let id: String
    public let name: String
    public let currentValue: String
    public let availableValues: [String]

    public init(id: String, name: String, currentValue: String, availableValues: [String]) {
        self.id = id
        self.name = name
        self.currentValue = currentValue
        self.availableValues = availableValues
    }
}

// MARK: - Captured Image Result

/// The result of a capture operation.
public struct CapturedImageResult: Sendable {
    /// Full-resolution JPEG data, if immediately available.
    public let imageData: Data?
    /// URL to download the image from the camera (for deferred download).
    public let remoteURL: URL?
    /// Filename on the camera's storage.
    public let filename: String?
    /// Timestamp of capture.
    public let timestamp: Date

    public init(imageData: Data? = nil, remoteURL: URL? = nil, filename: String? = nil, timestamp: Date = Date()) {
        self.imageData = imageData
        self.remoteURL = remoteURL
        self.filename = filename
        self.timestamp = timestamp
    }
}

// MARK: - Media Item

/// Represents a file on the camera's storage.
public struct CameraMediaItem: Identifiable, Sendable {
    public let id: String
    public let filename: String
    public let directory: String
    public let fileSize: Int64
    public let creationDate: Date?
    public let thumbnailURL: URL?
    public let downloadURL: URL

    public init(id: String, filename: String, directory: String, fileSize: Int64,
                creationDate: Date?, thumbnailURL: URL?, downloadURL: URL) {
        self.id = id
        self.filename = filename
        self.directory = directory
        self.fileSize = fileSize
        self.creationDate = creationDate
        self.thumbnailURL = thumbnailURL
        self.downloadURL = downloadURL
    }
}

// MARK: - External Camera Protocol

/// The universal protocol that all camera adapters must implement.
/// This enables the photo booth app to work with any camera source through a single interface.
public protocol ExternalCameraSource: AnyObject {

    // MARK: - Identity

    /// The type/brand of this camera.
    var sourceType: CameraSourceType { get }

    /// Human-readable name (e.g., "GoPro HERO12 Black", "Canon EOS R5").
    var displayName: String { get }

    /// Unique identifier for this specific camera (serial number or UUID).
    var identifier: String { get }

    // MARK: - Connection State

    /// Current connection state. Observe via Combine publisher.
    var connectionState: CameraConnectionState { get }

    /// Publisher that emits connection state changes.
    var connectionStatePublisher: AnyPublisher<CameraConnectionState, Never> { get }

    /// What this camera can do.
    var capabilities: CameraCapabilities { get }

    // MARK: - Connection Lifecycle

    /// Initiate connection to the camera.
    func connect() async throws

    /// Gracefully disconnect from the camera.
    func disconnect() async

    // MARK: - Capture

    /// Trigger a still photo capture. Returns the captured image result.
    func capturePhoto() async throws -> CapturedImageResult

    /// Start video recording.
    func startVideoRecording() async throws

    /// Stop video recording and return the recorded file info.
    func stopVideoRecording() async throws -> CapturedImageResult

    // MARK: - Live Preview

    /// Start the live preview stream. Frames are delivered via the returned AsyncStream.
    /// Each frame is a CIImage suitable for display or processing.
    func startLivePreview() async throws -> AsyncStream<CIImage>

    /// Stop the live preview stream.
    func stopLivePreview() async throws

    // MARK: - Media Access

    /// List media files on the camera's storage.
    func listMedia() async throws -> [CameraMediaItem]

    /// Download a specific media file from the camera.
    func downloadMedia(_ item: CameraMediaItem) async throws -> Data

    // MARK: - Settings

    /// Get all available camera settings.
    func getSettings() async throws -> [CameraSetting]

    /// Set a camera setting to a new value.
    func setSetting(id: String, value: String) async throws

    // MARK: - Battery

    /// Current battery level (0-100), or nil if not supported.
    func getBatteryLevel() async throws -> Int?
}

// MARK: - Default Implementations

/// Default implementations for optional capabilities, so adapters only implement what they support.
public extension ExternalCameraSource {

    func startVideoRecording() async throws {
        throw CameraError.unsupportedOperation("Video recording not supported on \(displayName)")
    }

    func stopVideoRecording() async throws -> CapturedImageResult {
        throw CameraError.unsupportedOperation("Video recording not supported on \(displayName)")
    }

    func listMedia() async throws -> [CameraMediaItem] {
        throw CameraError.unsupportedOperation("Media listing not supported on \(displayName)")
    }

    func downloadMedia(_ item: CameraMediaItem) async throws -> Data {
        throw CameraError.unsupportedOperation("Media download not supported on \(displayName)")
    }

    func getSettings() async throws -> [CameraSetting] {
        return []
    }

    func setSetting(id: String, value: String) async throws {
        throw CameraError.unsupportedOperation("Settings control not supported on \(displayName)")
    }

    func getBatteryLevel() async throws -> Int? {
        return nil
    }
}

// MARK: - Camera Discovery Protocol

/// Protocol for discovering cameras on the network or via BLE.
public protocol CameraDiscoveryService: AnyObject {

    /// The camera brand this discovery service handles.
    var sourceType: CameraSourceType { get }

    /// Start scanning for cameras. Discovered cameras are emitted via the publisher.
    func startScanning()

    /// Stop scanning for cameras.
    func stopScanning()

    /// Publisher that emits newly discovered cameras.
    var discoveredCamerasPublisher: AnyPublisher<ExternalCameraSource, Never> { get }
}

// MARK: - Camera Manager

/// Central manager that coordinates multiple camera sources and discovery services.
/// The photo booth app interacts primarily with this manager.
@Observable
public final class CameraSourceManager {

    // MARK: - Published State

    /// All currently known cameras (discovered + connected).
    public private(set) var availableCameras: [ExternalCameraSource] = []

    /// The currently active camera source being used by the photo booth.
    public var activeCamera: ExternalCameraSource?

    // MARK: - Private

    private var discoveryServices: [CameraDiscoveryService] = []
    private var cancellables = Set<AnyCancellable>()

    public init() {}

    // MARK: - Registration

    /// Register a discovery service for a camera brand.
    public func registerDiscoveryService(_ service: CameraDiscoveryService) {
        discoveryServices.append(service)

        service.discoveredCamerasPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] camera in
                guard let self = self else { return }
                // Avoid duplicates
                if !self.availableCameras.contains(where: { $0.identifier == camera.identifier }) {
                    self.availableCameras.append(camera)
                }
            }
            .store(in: &cancellables)
    }

    /// Manually add a camera source (e.g., built-in camera).
    public func addCamera(_ camera: ExternalCameraSource) {
        if !availableCameras.contains(where: { $0.identifier == camera.identifier }) {
            availableCameras.append(camera)
        }
    }

    // MARK: - Discovery

    /// Start scanning for all registered camera types.
    public func startDiscovery() {
        for service in discoveryServices {
            service.startScanning()
        }
    }

    /// Stop all scanning.
    public func stopDiscovery() {
        for service in discoveryServices {
            service.stopScanning()
        }
    }

    // MARK: - Camera Switching

    /// Switch the active camera. Disconnects the previous camera and connects the new one.
    public func switchTo(_ camera: ExternalCameraSource) async throws {
        // Disconnect previous camera
        if let current = activeCamera {
            await current.disconnect()
        }

        // Connect new camera
        try await camera.connect()
        activeCamera = camera
    }

    /// Convenience: capture photo from the active camera.
    public func capturePhoto() async throws -> CapturedImageResult {
        guard let camera = activeCamera else {
            throw CameraError.noCameraSelected
        }
        return try await camera.capturePhoto()
    }

    /// Convenience: start live preview from the active camera.
    public func startLivePreview() async throws -> AsyncStream<CIImage> {
        guard let camera = activeCamera else {
            throw CameraError.noCameraSelected
        }
        return try await camera.startLivePreview()
    }
}

// MARK: - Errors

public enum CameraError: LocalizedError {
    case noCameraSelected
    case connectionFailed(String)
    case commandFailed(String)
    case unsupportedOperation(String)
    case timeout
    case bleNotAvailable
    case wifiConnectionFailed
    case downloadFailed(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .noCameraSelected:
            return "No camera is currently selected."
        case .connectionFailed(let detail):
            return "Camera connection failed: \(detail)"
        case .commandFailed(let detail):
            return "Camera command failed: \(detail)"
        case .unsupportedOperation(let detail):
            return detail
        case .timeout:
            return "Camera operation timed out."
        case .bleNotAvailable:
            return "Bluetooth Low Energy is not available."
        case .wifiConnectionFailed:
            return "Failed to connect to camera WiFi network."
        case .downloadFailed(let detail):
            return "Failed to download from camera: \(detail)"
        case .invalidResponse:
            return "Received an invalid response from the camera."
        }
    }
}
