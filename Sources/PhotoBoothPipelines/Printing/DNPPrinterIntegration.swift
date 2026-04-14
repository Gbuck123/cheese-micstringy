// DNPPrinterIntegration.swift
// Integration layer for DNP dye-sublimation printers (DS620, DS820, DS-RX1HS).
//
// ## DNP Printer iOS Integration Overview
//
// DNP does NOT provide a public iOS SDK for direct printer control.
// Their printers connect to iPads through one of these methods:
//
// 1. **AirPrint (Recommended for most setups)**:
//    DNP DS620A, DS820A, and DS-RX1HS support AirPrint when connected via:
//    - USB to a Mac/PC running DNP's print server software
//    - A dedicated wireless print server (e.g., Silex DS-510)
//    - DNP's own WPS-1 wireless print server accessory
//
// 2. **DNP WPS-1 Wireless Print Server**:
//    DNP sells the WPS-1 accessory that plugs into the printer's USB port
//    and creates a WiFi access point. It exposes the printer as an AirPrint
//    device. No special SDK needed -- use standard UIPrintInteractionController.
//
// 3. **DNP Mobile Print SDK (Android only)**:
//    DNP has an Android SDK for direct USB-OTG printing. As of 2025,
//    there is NO official iOS SDK. iOS integration goes through AirPrint.
//
// 4. **Third-party middleware**:
//    Products like "Breeze DSLR Remote Pro" or "dslrBooth" run on a
//    Mac/PC and expose a REST API or shared folder that the iPad app
//    can send images to.
//
// This file provides:
// - A wrapper for DNP printers accessed via AirPrint
// - Media type detection and paper size validation
// - Print count tracking (DNP printers have specific media roll capacities)
// - A network print server client for custom DNP print server setups

import UIKit
import os.log

// MARK: - DNP Printer Models

public enum DNPPrinterModel: String, CaseIterable, Sendable {
    case ds620a = "DS620A"
    case ds820a = "DS820A"
    case dsRX1HS = "DS-RX1HS"
    case ds40 = "DS40"
    case ds80 = "DS80"

    /// Supported media sizes for this printer model.
    public var supportedMediaSizes: [DNPMediaSize] {
        switch self {
        case .ds620a:
            return [.fourBySix, .fiveBySeven, .sixByEight, .sixByNine,
                    .twoBySixStrip, .threeFiveByFive]
        case .ds820a:
            return [.eightByTen, .eightByTwelve, .eightBySix,
                    .fourBySixFromEight]
        case .dsRX1HS:
            return [.fourBySix, .fiveBySeven, .sixByEight,
                    .twoBySixStrip, .threeFiveByFive]
        case .ds40:
            return [.fourBySix, .fiveBySeven, .sixByEight]
        case .ds80:
            return [.eightByTen, .eightByTwelve]
        }
    }

    /// Prints per media roll for 4x6 (or equivalent primary size).
    public var printsPerRoll: Int {
        switch self {
        case .ds620a:   return 400  // 4x6 media
        case .ds820a:   return 130  // 8x10 media
        case .dsRX1HS:  return 700  // 4x6 media
        case .ds40:     return 400
        case .ds80:     return 130
        }
    }

    /// Average print time in seconds.
    public var averagePrintTimeSeconds: TimeInterval {
        switch self {
        case .ds620a:   return 8.5   // 4x6
        case .ds820a:   return 16.0  // 8x10
        case .dsRX1HS:  return 7.8   // 4x6, fastest in class
        case .ds40:     return 9.0
        case .ds80:     return 17.0
        }
    }
}

public enum DNPMediaSize: String, Sendable {
    case fourBySix = "4x6"
    case fiveBySeven = "5x7"
    case sixByEight = "6x8"
    case sixByNine = "6x9"
    case eightByTen = "8x10"
    case eightByTwelve = "8x12"
    case eightBySix = "8x6"           // DS820 can cut 8x12 to 8x6
    case twoBySixStrip = "2x6"        // Two strips on 4x6 media
    case threeFiveByFive = "3.5x5"
    case fourBySixFromEight = "4x6*"  // DS820 cutting 8x12 into two 4x6

    public var pixelsAt300DPI: CGSize {
        switch self {
        case .fourBySix:          return CGSize(width: 1200, height: 1800)
        case .fiveBySeven:        return CGSize(width: 1500, height: 2100)
        case .sixByEight:         return CGSize(width: 1800, height: 2400)
        case .sixByNine:          return CGSize(width: 1800, height: 2700)
        case .eightByTen:         return CGSize(width: 2400, height: 3000)
        case .eightByTwelve:      return CGSize(width: 2400, height: 3600)
        case .eightBySix:         return CGSize(width: 2400, height: 1800)
        case .twoBySixStrip:      return CGSize(width: 1200, height: 1800) // Printed on 4x6
        case .threeFiveByFive:    return CGSize(width: 1050, height: 1500)
        case .fourBySixFromEight: return CGSize(width: 1200, height: 1800)
        }
    }
}

// MARK: - DNP AirPrint Wrapper

/// Wraps AirPrintService with DNP-specific logic: media tracking, print validation,
/// and printer identification.
public final class DNPPrinterService: ObservableObject {

    // MARK: Properties

    @Published public var detectedModel: DNPPrinterModel?
    @Published public var estimatedPrintsRemaining: Int?
    @Published public var totalPrintsMade: Int = 0

    private let airPrintService: AirPrintService
    private let logger = Logger(subsystem: "com.photobooth", category: "DNPPrinter")

    // Persistence keys
    private enum Keys {
        static let model = "DNP.printerModel"
        static let printsOnRoll = "DNP.printsOnCurrentRoll"
        static let totalPrints = "DNP.totalPrintsMade"
    }

    // MARK: Init

    public init(airPrintService: AirPrintService = AirPrintService()) {
        self.airPrintService = airPrintService
        loadState()
    }

    // MARK: - Printer Setup

    /// Shows the system printer picker and attempts to identify the DNP model.
    @MainActor
    public func selectPrinter(from viewController: UIViewController) async -> Bool {
        guard let printer = await airPrintService.showPrinterPicker(from: viewController) else {
            return false
        }

        // Try to identify the DNP model from the printer name
        identifyModel(from: printer.displayName)

        logger.info("Selected printer: \(printer.displayName) (model: \(self.detectedModel?.rawValue ?? "unknown"))")
        return true
    }

    /// Manually set the printer model (useful if auto-detection fails).
    public func setModel(_ model: DNPPrinterModel) {
        detectedModel = model
        estimatedPrintsRemaining = model.printsPerRoll
        saveState()
    }

    /// Reset the media roll counter (call when loading new media).
    public func resetMediaCounter() {
        guard let model = detectedModel else { return }
        estimatedPrintsRemaining = model.printsPerRoll
        saveState()
    }

    // MARK: - Print with DNP Awareness

    /// Prints an image with DNP-specific validation and media tracking.
    @MainActor
    public func print(image: UIImage,
                      mediaSize: DNPMediaSize = .fourBySix,
                      copies: Int = 1) async -> PrintJobResult {

        // Validate media size against printer model
        if let model = detectedModel {
            guard model.supportedMediaSizes.contains(mediaSize) else {
                logger.error("Media size \(mediaSize.rawValue) not supported by \(model.rawValue)")
                return .failed(PrintError.unsupportedPaperSize)
            }

            // Check media remaining
            if let remaining = estimatedPrintsRemaining, remaining < copies {
                logger.warning("Low media warning: \(remaining) prints remaining, \(copies) requested")
                // Don't block, just warn. The printer will error if truly out.
            }
        }

        // Ensure image matches expected pixel dimensions
        let targetPixels = mediaSize.pixelsAt300DPI
        let printImage: UIImage
        if abs(image.size.width - targetPixels.width) > 10 ||
            abs(image.size.height - targetPixels.height) > 10 {
            // Resize to exact DNP media dimensions
            printImage = resizeForDNP(image: image, targetSize: targetPixels) ?? image
        } else {
            printImage = image
        }

        // Configure for the paper size
        var config = PhotoBoothPrintConfig()
        config.paperSize = airPrintPaperSize(for: mediaSize)
        config.numberOfCopies = copies
        config.jobName = "DNP Photo Booth Print"

        // Print
        let result: PrintJobResult
        if copies > 1 {
            let results = await airPrintService.printSilentMultipleCopies(
                image: printImage, config: config, copies: copies
            )
            if results.allSatisfy({ if case .success = $0 { return true }; return false }) {
                result = .success(printerURL: airPrintService.lastPrinterURL)
            } else if let failure = results.first(where: { if case .failed = $0 { return true }; return false }) {
                result = failure
            } else {
                result = .cancelled
            }
        } else {
            result = await airPrintService.printSilent(image: printImage, config: config)
        }

        // Update media tracking
        if case .success = result {
            totalPrintsMade += copies
            if estimatedPrintsRemaining != nil {
                estimatedPrintsRemaining! -= copies
                estimatedPrintsRemaining = max(0, estimatedPrintsRemaining!)
            }
            saveState()
        }

        return result
    }

    // MARK: - Helpers

    private func identifyModel(from printerName: String) {
        let name = printerName.uppercased()

        for model in DNPPrinterModel.allCases {
            if name.contains(model.rawValue.uppercased()) ||
                name.contains(model.rawValue.replacingOccurrences(of: "-", with: "").uppercased()) {
                detectedModel = model
                if estimatedPrintsRemaining == nil {
                    estimatedPrintsRemaining = model.printsPerRoll
                }
                saveState()
                return
            }
        }

        // Generic DNP detection
        if name.contains("DNP") || name.contains("DAI NIPPON") {
            logger.info("Detected DNP printer but could not determine specific model.")
        }
    }

    private func airPrintPaperSize(for mediaSize: DNPMediaSize) -> PhotoBoothPrintConfig.PaperSize {
        switch mediaSize {
        case .fourBySix, .twoBySixStrip, .fourBySixFromEight:
            return .fourBySix
        case .fiveBySeven, .threeFiveByFive:
            return .fiveBySeven
        case .eightByTen, .eightBySix:
            return .eightByTen
        default:
            return .fourBySix
        }
    }

    private func resizeForDNP(image: UIImage, targetSize: CGSize) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            // Aspect fill and center-crop for exact DNP dimensions
            let imageAspect = image.size.width / image.size.height
            let targetAspect = targetSize.width / targetSize.height

            let drawRect: CGRect
            if imageAspect > targetAspect {
                let scaledWidth = targetSize.height * imageAspect
                drawRect = CGRect(
                    x: (targetSize.width - scaledWidth) / 2,
                    y: 0,
                    width: scaledWidth,
                    height: targetSize.height
                )
            } else {
                let scaledHeight = targetSize.width / imageAspect
                drawRect = CGRect(
                    x: 0,
                    y: (targetSize.height - scaledHeight) / 2,
                    width: targetSize.width,
                    height: scaledHeight
                )
            }

            image.draw(in: drawRect)
        }
    }

    // MARK: - Persistence

    private func saveState() {
        let defaults = UserDefaults.standard
        defaults.set(detectedModel?.rawValue, forKey: Keys.model)
        defaults.set(estimatedPrintsRemaining, forKey: Keys.printsOnRoll)
        defaults.set(totalPrintsMade, forKey: Keys.totalPrints)
    }

    private func loadState() {
        let defaults = UserDefaults.standard
        if let modelName = defaults.string(forKey: Keys.model) {
            detectedModel = DNPPrinterModel(rawValue: modelName)
        }
        let remaining = defaults.integer(forKey: Keys.printsOnRoll)
        estimatedPrintsRemaining = remaining > 0 ? remaining : nil
        totalPrintsMade = defaults.integer(forKey: Keys.totalPrints)
    }
}

// MARK: - DNP Network Print Server Client

/// For setups where a Mac/PC runs a print server that accepts images via HTTP.
/// This is common in professional photo booth setups where the iPad sends images
/// to a connected computer that drives the DNP printer directly.
///
/// Protocol: POST image data to the server, receive job status via polling or websocket.
public final class DNPNetworkPrintClient {

    public struct ServerConfig {
        public let baseURL: URL           // e.g., http://192.168.1.100:8080
        public let apiKey: String?        // Optional authentication
        public var timeout: TimeInterval = 30

        public init(baseURL: URL, apiKey: String? = nil) {
            self.baseURL = baseURL
            self.apiKey = apiKey
        }
    }

    public enum NetworkPrintStatus: String, Codable {
        case queued
        case printing
        case completed
        case error
    }

    public struct NetworkPrintResponse: Codable {
        public let jobId: String
        public let status: NetworkPrintStatus
        public let message: String?
        public let estimatedTimeSeconds: Int?
    }

    private let config: ServerConfig
    private let session: URLSession
    private let logger = Logger(subsystem: "com.photobooth", category: "DNPNetworkPrint")

    public init(config: ServerConfig) {
        self.config = config
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = config.timeout
        self.session = URLSession(configuration: sessionConfig)
    }

    /// Submit a print job to the network print server.
    public func submitPrintJob(image: UIImage,
                               mediaSize: DNPMediaSize = .fourBySix,
                               copies: Int = 1) async throws -> NetworkPrintResponse {
        let url = config.baseURL.appendingPathComponent("/api/print")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        // Build multipart form data
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        if let apiKey = config.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        guard let imageData = image.jpegData(compressionQuality: 0.95) else {
            throw PrintError.imageRenderingFailed
        }

        var body = Data()
        // Image field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"print.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)

        // Media size field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"mediaSize\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(mediaSize.rawValue)\r\n".data(using: .utf8)!)

        // Copies field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"copies\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(copies)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw PrintError.printJobFailed("Server returned status \(statusCode)")
        }

        return try JSONDecoder().decode(NetworkPrintResponse.self, from: data)
    }

    /// Poll for job status.
    public func checkJobStatus(jobId: String) async throws -> NetworkPrintResponse {
        let url = config.baseURL.appendingPathComponent("/api/print/\(jobId)/status")
        var request = URLRequest(url: url)

        if let apiKey = config.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(NetworkPrintResponse.self, from: data)
    }

    /// Poll until job completes or fails, with timeout.
    public func waitForCompletion(jobId: String,
                                  pollInterval: TimeInterval = 2,
                                  timeout: TimeInterval = 120) async throws -> NetworkPrintResponse {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let status = try await checkJobStatus(jobId: jobId)

            switch status.status {
            case .completed:
                return status
            case .error:
                throw PrintError.printJobFailed(status.message ?? "Unknown printer error")
            case .queued, .printing:
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        }

        throw PrintError.printJobFailed("Print job timed out after \(Int(timeout)) seconds")
    }

    /// Check if the print server is reachable.
    public func ping() async -> Bool {
        let url = config.baseURL.appendingPathComponent("/api/health")
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
