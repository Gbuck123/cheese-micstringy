// IPPPrintClient.swift
// Internet Printing Protocol (IPP) client for iOS.
//
// ## Can iOS apps use IPP directly?
//
// YES, but with important caveats:
//
// 1. **AirPrint IS IPP**: AirPrint is built on IPP/2.0 + mDNS/Bonjour discovery.
//    When you use UIPrintInteractionController, iOS is sending IPP requests under the hood.
//    You cannot bypass or customize this behavior.
//
// 2. **Direct IPP from iOS**: You CAN send raw HTTP requests to an IPP endpoint
//    because IPP is just HTTP POST to port 631 with a specific binary payload format.
//    This gives you more control than UIPrintInteractionController but requires you to:
//    - Construct IPP binary messages manually
//    - Handle IPP attribute negotiation
//    - Manage the print data format (PDF, JPEG, PWG Raster)
//
// 3. **When to use direct IPP**:
//    - You need precise control over print attributes not exposed by AirPrint API
//    - You're printing to a CUPS server on the local network
//    - You need to query printer status (ink levels, paper loaded, etc.)
//    - You want to send pre-formatted raster data for exact pixel placement
//
// 4. **Limitations**:
//    - iOS App Transport Security (ATS) may block non-HTTPS connections to port 631
//      (add NSAllowsLocalNetworking = true to Info.plist)
//    - Constructing PWG Raster format is complex
//    - Most dye-sub printers don't run their own IPP server; they connect via USB
//      to a host that runs CUPS
//
// This file provides a lightweight IPP client for advanced print control.

import Foundation
import Network
import os.log

// MARK: - IPP Constants

/// IPP operation codes (RFC 8011).
public enum IPPOperation: UInt16 {
    case printJob = 0x0002
    case validateJob = 0x0004
    case cancelJob = 0x0008
    case getJobAttributes = 0x0009
    case getPrinterAttributes = 0x000B
    case createJob = 0x0005
    case sendDocument = 0x0006
}

/// IPP status codes.
public enum IPPStatus: UInt16 {
    case successfulOK = 0x0000
    case successfulOKIgnoredOrSubstitutedAttributes = 0x0001
    case clientErrorBadRequest = 0x0400
    case clientErrorForbidden = 0x0401
    case clientErrorNotAuthenticated = 0x0402
    case clientErrorNotFound = 0x0406
    case clientErrorDocumentFormatNotSupported = 0x040A
    case serverErrorInternalError = 0x0500
    case serverErrorOperationNotSupported = 0x0501
    case serverErrorBusy = 0x0503

    public var isSuccess: Bool { rawValue < 0x0400 }
}

/// IPP attribute value tags.
public enum IPPValueTag: UInt8 {
    case integer = 0x21
    case boolean = 0x22
    case enumValue = 0x23
    case textWithoutLanguage = 0x41
    case nameWithoutLanguage = 0x42
    case keyword = 0x44
    case uri = 0x45
    case charset = 0x47
    case naturalLanguage = 0x48
    case mimeMediaType = 0x49
}

/// IPP delimiter tags.
public enum IPPDelimiterTag: UInt8 {
    case operationAttributes = 0x01
    case jobAttributes = 0x02
    case endOfAttributes = 0x03
    case printerAttributes = 0x04
}

// MARK: - IPP Message Builder

/// Builds IPP binary messages conforming to RFC 8011.
public struct IPPMessageBuilder {

    private var data = Data()
    private var requestId: Int32 = 1

    /// Create a new IPP request.
    public init(operation: IPPOperation, requestId: Int32 = 1) {
        self.requestId = requestId

        // IPP version 2.0
        data.append(contentsOf: [0x02, 0x00])
        // Operation ID
        var opId = operation.rawValue.bigEndian
        data.append(Data(bytes: &opId, count: 2))
        // Request ID
        var reqId = requestId.bigEndian
        data.append(Data(bytes: &reqId, count: 4))
    }

    /// Begin operation attributes group.
    public mutating func beginOperationAttributes() {
        data.append(IPPDelimiterTag.operationAttributes.rawValue)
    }

    /// Begin job attributes group.
    public mutating func beginJobAttributes() {
        data.append(IPPDelimiterTag.jobAttributes.rawValue)
    }

    /// End attributes section.
    public mutating func endAttributes() {
        data.append(IPPDelimiterTag.endOfAttributes.rawValue)
    }

    /// Add a keyword attribute (e.g., "media", "print-quality").
    public mutating func addKeyword(name: String, value: String) {
        addAttribute(tag: .keyword, name: name, value: value.data(using: .utf8) ?? Data())
    }

    /// Add a URI attribute.
    public mutating func addURI(name: String, value: String) {
        addAttribute(tag: .uri, name: name, value: value.data(using: .utf8) ?? Data())
    }

    /// Add a charset attribute.
    public mutating func addCharset(name: String, value: String) {
        addAttribute(tag: .charset, name: name, value: value.data(using: .utf8) ?? Data())
    }

    /// Add a natural language attribute.
    public mutating func addNaturalLanguage(name: String, value: String) {
        addAttribute(tag: .naturalLanguage, name: name, value: value.data(using: .utf8) ?? Data())
    }

    /// Add a name attribute.
    public mutating func addName(name: String, value: String) {
        addAttribute(tag: .nameWithoutLanguage, name: name, value: value.data(using: .utf8) ?? Data())
    }

    /// Add an integer attribute.
    public mutating func addInteger(name: String, value: Int32) {
        var bigEndian = value.bigEndian
        let valueData = Data(bytes: &bigEndian, count: 4)
        addAttribute(tag: .integer, name: name, value: valueData)
    }

    /// Add an enum attribute (same encoding as integer in IPP).
    public mutating func addEnum(name: String, value: Int32) {
        var bigEndian = value.bigEndian
        let valueData = Data(bytes: &bigEndian, count: 4)
        addAttribute(tag: .enumValue, name: name, value: valueData)
    }

    /// Add a boolean attribute.
    public mutating func addBoolean(name: String, value: Bool) {
        addAttribute(tag: .boolean, name: name, value: Data([value ? 0x01 : 0x00]))
    }

    /// Add a MIME type attribute.
    public mutating func addMimeType(name: String, value: String) {
        addAttribute(tag: .mimeMediaType, name: name, value: value.data(using: .utf8) ?? Data())
    }

    /// Append raw document data (the actual image/PDF to print).
    public mutating func appendDocumentData(_ documentData: Data) {
        data.append(documentData)
    }

    /// Build the final IPP message.
    public func build() -> Data {
        return data
    }

    // MARK: Private

    private mutating func addAttribute(tag: IPPValueTag, name: String, value: Data) {
        // Value tag
        data.append(tag.rawValue)
        // Name length + name
        let nameData = name.data(using: .utf8) ?? Data()
        var nameLength = UInt16(nameData.count).bigEndian
        data.append(Data(bytes: &nameLength, count: 2))
        data.append(nameData)
        // Value length + value
        var valueLength = UInt16(value.count).bigEndian
        data.append(Data(bytes: &valueLength, count: 2))
        data.append(value)
    }
}

// MARK: - IPP Client

/// A lightweight IPP client for communicating with printers/CUPS servers.
///
/// Usage:
/// ```swift
/// let client = IPPPrintClient(printerURL: URL(string: "http://192.168.1.100:631/printers/DNP_DS620")!)
///
/// // Get printer attributes (status, media loaded, etc.)
/// let attrs = try await client.getPrinterAttributes()
///
/// // Print a JPEG image
/// let jobId = try await client.printJPEG(imageData: jpegData, jobName: "Booth Print")
///
/// // Check job status
/// let status = try await client.getJobStatus(jobId: jobId)
/// ```
public final class IPPPrintClient {

    public let printerURL: URL
    private let session: URLSession
    private var nextRequestId: Int32 = 1
    private let logger = Logger(subsystem: "com.photobooth", category: "IPP")

    public init(printerURL: URL) {
        self.printerURL = printerURL

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    // MARK: - Get Printer Attributes

    /// Queries the printer for its current attributes (status, media, capabilities).
    public func getPrinterAttributes() async throws -> [String: Any] {
        var builder = IPPMessageBuilder(operation: .getPrinterAttributes, requestId: nextRequestId)
        nextRequestId += 1

        builder.beginOperationAttributes()
        builder.addCharset(name: "attributes-charset", value: "utf-8")
        builder.addNaturalLanguage(name: "attributes-natural-language", value: "en-us")
        builder.addURI(name: "printer-uri", value: printerURL.absoluteString)
        // Request specific attributes relevant to photo booth operation
        builder.addKeyword(name: "requested-attributes", value: "printer-state")
        builder.addKeyword(name: "requested-attributes", value: "printer-state-reasons")
        builder.addKeyword(name: "requested-attributes", value: "media-ready")
        builder.addKeyword(name: "requested-attributes", value: "media-supported")
        builder.addKeyword(name: "requested-attributes", value: "printer-name")
        builder.addKeyword(name: "requested-attributes", value: "printer-make-and-model")
        builder.endAttributes()

        let responseData = try await sendIPPRequest(builder.build())
        return parseIPPResponse(responseData)
    }

    // MARK: - Print JPEG

    /// Sends a JPEG image as a print job.
    /// Returns the IPP job ID on success.
    public func printJPEG(imageData: Data,
                          jobName: String = "Photo Booth Print",
                          copies: Int = 1,
                          mediaSize: String? = nil,
                          quality: IPPPrintQuality = .high) async throws -> Int32 {
        var builder = IPPMessageBuilder(operation: .printJob, requestId: nextRequestId)
        nextRequestId += 1

        // Operation attributes
        builder.beginOperationAttributes()
        builder.addCharset(name: "attributes-charset", value: "utf-8")
        builder.addNaturalLanguage(name: "attributes-natural-language", value: "en-us")
        builder.addURI(name: "printer-uri", value: printerURL.absoluteString)
        builder.addName(name: "requesting-user-name", value: "PhotoBooth")
        builder.addName(name: "job-name", value: jobName)
        builder.addMimeType(name: "document-format", value: "image/jpeg")

        // Job attributes
        builder.beginJobAttributes()
        builder.addInteger(name: "copies", value: Int32(copies))
        builder.addEnum(name: "print-quality", value: quality.rawValue)

        // Media size (IPP keyword)
        if let media = mediaSize {
            builder.addKeyword(name: "media", value: media)
        } else {
            // Default to 4x6 photo paper
            builder.addKeyword(name: "media", value: "na_index-4x6_4x6in")
        }

        // Photo-specific settings
        builder.addKeyword(name: "print-color-mode", value: "color")
        builder.addKeyword(name: "print-content-optimize", value: "photo")

        builder.endAttributes()

        // Append the JPEG data as the document
        builder.appendDocumentData(imageData)

        let responseData = try await sendIPPRequest(builder.build())
        let parsed = parseIPPResponse(responseData)

        if let jobId = parsed["job-id"] as? Int32 {
            logger.info("Print job submitted: ID \(jobId)")
            return jobId
        }

        throw PrintError.printJobFailed("No job ID in IPP response")
    }

    // MARK: - Get Job Status

    /// Queries the status of a print job.
    public func getJobStatus(jobId: Int32) async throws -> IPPJobStatus {
        var builder = IPPMessageBuilder(operation: .getJobAttributes, requestId: nextRequestId)
        nextRequestId += 1

        builder.beginOperationAttributes()
        builder.addCharset(name: "attributes-charset", value: "utf-8")
        builder.addNaturalLanguage(name: "attributes-natural-language", value: "en-us")
        builder.addURI(name: "printer-uri", value: printerURL.absoluteString)
        builder.addInteger(name: "job-id", value: jobId)
        builder.addKeyword(name: "requested-attributes", value: "job-state")
        builder.addKeyword(name: "requested-attributes", value: "job-state-reasons")
        builder.endAttributes()

        let responseData = try await sendIPPRequest(builder.build())
        let parsed = parseIPPResponse(responseData)

        if let stateValue = parsed["job-state"] as? Int32,
           let state = IPPJobStatus.State(rawValue: stateValue) {
            let reasons = parsed["job-state-reasons"] as? String
            return IPPJobStatus(state: state, reasons: reasons)
        }

        return IPPJobStatus(state: .unknown, reasons: nil)
    }

    // MARK: - Cancel Job

    /// Cancels a print job.
    public func cancelJob(jobId: Int32) async throws {
        var builder = IPPMessageBuilder(operation: .cancelJob, requestId: nextRequestId)
        nextRequestId += 1

        builder.beginOperationAttributes()
        builder.addCharset(name: "attributes-charset", value: "utf-8")
        builder.addNaturalLanguage(name: "attributes-natural-language", value: "en-us")
        builder.addURI(name: "printer-uri", value: printerURL.absoluteString)
        builder.addInteger(name: "job-id", value: jobId)
        builder.endAttributes()

        _ = try await sendIPPRequest(builder.build())
        logger.info("Cancelled job \(jobId)")
    }

    // MARK: - IPP Media Keywords for Photo Booth

    /// Standard IPP media keywords for common photo booth sizes.
    public enum IPPMediaKeyword: String {
        case fourBySix = "na_index-4x6_4x6in"
        case fiveBySeven = "na_5x7_5x7in"
        case eightByTen = "na_govt-letter_8x10in"
        case letter = "na_letter_8.5x11in"
        case a6 = "iso_a6_105x148mm"
        case postcard = "jpn_hagaki_100x148mm"    // Japanese postcard, common in Asia

        /// Custom media size string for non-standard sizes.
        /// Format: "custom_{name}_{width}x{height}in"
        public static func custom(name: String, widthInches: Double, heightInches: Double) -> String {
            return "custom_\(name)_\(widthInches)x\(heightInches)in"
        }
    }

    // MARK: - HTTP Transport

    private func sendIPPRequest(_ ippData: Data) async throws -> Data {
        var request = URLRequest(url: printerURL)
        request.httpMethod = "POST"
        request.setValue("application/ipp", forHTTPHeaderField: "Content-Type")
        request.setValue("application/ipp", forHTTPHeaderField: "Accept")
        request.httpBody = ippData

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PrintError.printJobFailed("Invalid HTTP response from IPP server")
        }

        // IPP uses HTTP 200 for all responses (including errors)
        guard httpResponse.statusCode == 200 else {
            throw PrintError.printJobFailed("IPP server returned HTTP \(httpResponse.statusCode)")
        }

        return data
    }

    // MARK: - IPP Response Parser (Simplified)

    private func parseIPPResponse(_ data: Data) -> [String: Any] {
        var result: [String: Any] = [:]
        guard data.count >= 8 else { return result }

        // Parse header
        let statusCode = UInt16(data[2]) << 8 | UInt16(data[3])
        result["status-code"] = statusCode

        let requestId = Int32(data[4]) << 24 | Int32(data[5]) << 16 |
                         Int32(data[6]) << 8 | Int32(data[7])
        result["request-id"] = requestId

        // Parse attribute groups
        var offset = 8
        while offset < data.count {
            let tag = data[offset]
            offset += 1

            // Delimiter tags
            if tag == IPPDelimiterTag.endOfAttributes.rawValue {
                break
            }
            if tag <= 0x0F {
                // Group delimiter, continue to next attribute
                continue
            }

            // Value tag -- parse attribute
            guard offset + 2 <= data.count else { break }
            let nameLength = Int(UInt16(data[offset]) << 8 | UInt16(data[offset + 1]))
            offset += 2

            guard offset + nameLength <= data.count else { break }
            let nameData = data[offset..<(offset + nameLength)]
            let name = String(data: nameData, encoding: .utf8) ?? ""
            offset += nameLength

            guard offset + 2 <= data.count else { break }
            let valueLength = Int(UInt16(data[offset]) << 8 | UInt16(data[offset + 1]))
            offset += 2

            guard offset + valueLength <= data.count else { break }
            let valueData = data[offset..<(offset + valueLength)]
            offset += valueLength

            // Decode based on value tag
            switch tag {
            case IPPValueTag.integer.rawValue, IPPValueTag.enumValue.rawValue:
                if valueLength == 4 {
                    let intValue = Int32(valueData[valueData.startIndex]) << 24 |
                                   Int32(valueData[valueData.startIndex + 1]) << 16 |
                                   Int32(valueData[valueData.startIndex + 2]) << 8 |
                                   Int32(valueData[valueData.startIndex + 3])
                    result[name] = intValue
                }
            case IPPValueTag.boolean.rawValue:
                result[name] = valueData.first != 0
            default:
                // Text, keyword, URI, etc.
                if let stringValue = String(data: valueData, encoding: .utf8) {
                    result[name] = stringValue
                }
            }
        }

        return result
    }
}

// MARK: - IPP Types

public enum IPPPrintQuality: Int32 {
    case draft = 3
    case normal = 4
    case high = 5
}

public struct IPPJobStatus {
    public let state: State
    public let reasons: String?

    public enum State: Int32 {
        case pending = 3
        case pendingHeld = 4
        case processing = 5
        case processingStopped = 6
        case cancelled = 7
        case aborted = 8
        case completed = 9
        case unknown = -1

        public var isTerminal: Bool {
            switch self {
            case .cancelled, .aborted, .completed: return true
            default: return false
            }
        }
    }
}
