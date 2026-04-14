// VendorPrinterGuide.swift
// Reference data for all major photo booth printers and their iOS connectivity.
//
// This file serves as both a reference guide and a runtime registry for
// printer capabilities, connection methods, and SDK availability.

import Foundation

// MARK: - Printer Vendor Registry

/// Comprehensive registry of photo booth printers and their iOS integration paths.
public enum PhotoBoothPrinterVendor: String, CaseIterable {
    case dnp = "DNP"
    case hiti = "HiTi"
    case mitsubishi = "Mitsubishi"
    case canonSelphy = "Canon SELPHY"
    case sinfonia = "Sinfonia"    // Formerly Shinko/Ciaat

    public var printers: [PrinterSpec] {
        switch self {
        case .dnp:       return Self.dnpPrinters
        case .hiti:      return Self.hitiPrinters
        case .mitsubishi: return Self.mitsubishiPrinters
        case .canonSelphy: return Self.canonSelphyPrinters
        case .sinfonia:  return Self.sinfoniaPrinters
        }
    }

    // MARK: - DNP Printers
    //
    // DNP is the #1 photo booth printer brand globally.
    // iOS Integration: AirPrint via WPS-1 wireless server or USB-to-host print server.
    // NO native iOS SDK. Android has DNP Mobile Print SDK.
    //
    // Key points:
    // - DS-RX1HS: Fastest (7.8s for 4x6), 700 prints/roll, most popular for events
    // - DS620A: Versatile sizes, 400 prints/roll, good for studio + booth
    // - DS820A: Large format (8x10, 8x12), 130 prints/roll
    //
    // Connection to iPad:
    // 1. DNP WPS-1 Wireless Print Server ($199) - plugs into printer USB, creates WiFi AP
    //    Printer appears as AirPrint device. Best option for iPad photo booths.
    // 2. USB to Mac/PC + print server software (Breeze, dslrBooth, Darkroom Booth)
    //    iPad sends images to Mac/PC via network, Mac/PC drives printer.
    // 3. USB-C to iPad with Camera Connection Kit - LIMITED support, not recommended.
    //    iPadOS does not natively drive dye-sub printers over USB.
    //
    static var dnpPrinters: [PrinterSpec] {
        [
            PrinterSpec(
                model: "DS-RX1HS",
                vendor: .dnp,
                type: .dyeSublimation,
                mediaSizes: ["4x6", "5x7", "6x8", "2x6 strip"],
                maxPrintsPerRoll: 700,
                printSpeed4x6Seconds: 7.8,
                resolution: 300,
                connectionMethods: [.wifiViaWPS1, .usbToHostPC],
                airPrintSupport: .viaAccessory,
                vendorSDK: .init(
                    name: "DNP Mobile Print SDK",
                    platform: .androidOnly,
                    notes: "Android SDK via USB-OTG. No iOS SDK available. Use AirPrint via WPS-1."
                ),
                msrp: "$1,095",
                notes: "Best seller for photo booths. Fastest 4x6 dye-sub available."
            ),
            PrinterSpec(
                model: "DS620A",
                vendor: .dnp,
                type: .dyeSublimation,
                mediaSizes: ["4x6", "5x7", "6x8", "6x9", "2x6 strip", "3.5x5"],
                maxPrintsPerRoll: 400,
                printSpeed4x6Seconds: 8.5,
                resolution: 300,
                connectionMethods: [.wifiViaWPS1, .usbToHostPC],
                airPrintSupport: .viaAccessory,
                vendorSDK: nil,
                msrp: "$895",
                notes: "Most versatile size range. Supports partial cut for strip prints."
            ),
            PrinterSpec(
                model: "DS820A",
                vendor: .dnp,
                type: .dyeSublimation,
                mediaSizes: ["8x10", "8x12", "8x6", "8x4 (2-up from 8x12)"],
                maxPrintsPerRoll: 130,
                printSpeed4x6Seconds: 16.0,
                resolution: 300,
                connectionMethods: [.wifiViaWPS1, .usbToHostPC],
                airPrintSupport: .viaAccessory,
                vendorSDK: nil,
                msrp: "$1,695",
                notes: "Large format. Can cut 8x12 to 2x 4x6 or 2x 8x6."
            ),
        ]
    }

    // MARK: - HiTi Printers
    //
    // HiTi is the #2 photo booth printer brand. Based in Taiwan.
    // iOS Integration: HiTi has the BEST iOS support among dye-sub vendors.
    // They provide HiTi Mobile SDK for iOS with WiFi and USB printing.
    //
    // Key points:
    // - P525L: Compact, portable, WiFi built-in, iOS SDK available
    // - P750L: Large format (8x12), USB + WiFi
    // - Their iOS SDK supports direct WiFi printing without AirPrint
    //
    static var hitiPrinters: [PrinterSpec] {
        [
            PrinterSpec(
                model: "P525L",
                vendor: .hiti,
                type: .dyeSublimation,
                mediaSizes: ["4x6", "5x7", "6x8", "2x6 strip"],
                maxPrintsPerRoll: 500,
                printSpeed4x6Seconds: 10.0,
                resolution: 300,
                connectionMethods: [.wifiDirect, .usbToHostPC, .wifi],
                airPrintSupport: .notSupported,
                vendorSDK: .init(
                    name: "HiTi Mobile SDK",
                    platform: .iOSAndAndroid,
                    notes: """
                    HiTi provides an iOS framework (HiTiPrintSDK.framework).
                    - WiFi Direct printing (printer creates its own AP)
                    - Printer discovery via Bonjour/mDNS
                    - Media status and ink level reporting
                    - Custom print settings (color correction, sharpness)
                    Contact HiTi sales for SDK access: sdk@hiti.com
                    Requires NDA and developer agreement.
                    """
                ),
                msrp: "$699",
                notes: "Best iOS SDK support among dye-sub printers. WiFi built-in."
            ),
            PrinterSpec(
                model: "P750L",
                vendor: .hiti,
                type: .dyeSublimation,
                mediaSizes: ["4x6", "5x7", "6x8", "6x9", "8x12"],
                maxPrintsPerRoll: 400,
                printSpeed4x6Seconds: 9.0,
                resolution: 300,
                connectionMethods: [.wifiDirect, .usbToHostPC],
                airPrintSupport: .notSupported,
                vendorSDK: .init(
                    name: "HiTi Mobile SDK",
                    platform: .iOSAndAndroid,
                    notes: "Same SDK as P525L. Supports additional large format sizes."
                ),
                msrp: "$1,299",
                notes: "Large format option. Good for studios doing both 4x6 and 8x12."
            ),
        ]
    }

    // MARK: - Mitsubishi CP Series
    //
    // Mitsubishi Electric printers are popular in Asia-Pacific markets.
    // iOS Integration: AirPrint via USB host only. No iOS SDK.
    //
    // Key points:
    // - CP-D90DW: Double-deck (two media rolls), auto-switches sizes
    // - CP-M1A: Compact, fast, 300+ prints/roll
    // - CP-W5000DW: Large format, 8x10/8x12
    // No vendor iOS SDK. All iPad integration through AirPrint via host computer.
    //
    static var mitsubishiPrinters: [PrinterSpec] {
        [
            PrinterSpec(
                model: "CP-D90DW",
                vendor: .mitsubishi,
                type: .dyeSublimation,
                mediaSizes: ["4x6", "5x7", "6x8", "6x9", "3.5x5"],
                maxPrintsPerRoll: 400,
                printSpeed4x6Seconds: 7.8,
                resolution: 300,
                connectionMethods: [.usbToHostPC],
                airPrintSupport: .viaHostPC,
                vendorSDK: .init(
                    name: "Mitsubishi Print SDK",
                    platform: .windowsOnly,
                    notes: """
                    Windows DLL SDK only. No iOS/macOS SDK.
                    For iPad integration, use a Windows PC as print server.
                    Mitsubishi provides CUPS drivers for Linux which could
                    run on a Raspberry Pi as a print server.
                    """
                ),
                msrp: "$995",
                notes: "Double-deck design allows two different media sizes loaded simultaneously."
            ),
            PrinterSpec(
                model: "CP-M1A",
                vendor: .mitsubishi,
                type: .dyeSublimation,
                mediaSizes: ["4x6", "5x7", "6x8"],
                maxPrintsPerRoll: 300,
                printSpeed4x6Seconds: 8.0,
                resolution: 300,
                connectionMethods: [.usbToHostPC],
                airPrintSupport: .viaHostPC,
                vendorSDK: nil,
                msrp: "$749",
                notes: "Compact and affordable. Good entry-level dye-sub."
            ),
        ]
    }

    // MARK: - Canon SELPHY Series
    //
    // Canon SELPHY is the most consumer-accessible dye-sub printer.
    // iOS Integration: BEST native AirPrint support among all dye-sub printers.
    // WiFi built-in, AirPrint built-in, no accessories needed.
    //
    // HOWEVER: SELPHY is slow and has small media capacity (54 prints/pack).
    // Not recommended for high-volume events. Good for low-volume or personal booths.
    //
    static var canonSelphyPrinters: [PrinterSpec] {
        [
            PrinterSpec(
                model: "SELPHY CP1500",
                vendor: .canonSelphy,
                type: .dyeSublimation,
                mediaSizes: ["4x6", "Card size (2.1x3.4)", "Square (2.7x2.7)"],
                maxPrintsPerRoll: 54,   // Per media pack
                printSpeed4x6Seconds: 41.0,  // Very slow
                resolution: 300,
                connectionMethods: [.wifi, .usbDirect],
                airPrintSupport: .native,
                vendorSDK: .init(
                    name: "Canon PRINT SDK (EDSDK)",
                    platform: .iOSAndAndroid,
                    notes: """
                    Canon provides Canon PRINT Inkjet/SELPHY app with SDK support.
                    Also discoverable via AirPrint natively - no SDK needed.
                    WiFi Direct mode: printer creates its own AP.
                    AirPrint works over local WiFi network.
                    """
                ),
                msrp: "$129",
                notes: """
                Cheapest dye-sub option. Native AirPrint. But:
                - Only 54 prints per media pack ($0.55/print vs $0.12 for DNP)
                - 41 seconds per print (vs 8s for DNP DS-RX1HS)
                - Not suitable for events over ~50 guests
                """
            ),
            PrinterSpec(
                model: "SELPHY QX10",
                vendor: .canonSelphy,
                type: .dyeSublimation,
                mediaSizes: ["Square (2.7x2.7)"],
                maxPrintsPerRoll: 20,
                printSpeed4x6Seconds: 43.0,
                resolution: 287,
                connectionMethods: [.wifi, .bluetooth],
                airPrintSupport: .notSupported,
                vendorSDK: .init(
                    name: "Canon PRINT SDK",
                    platform: .iOSAndAndroid,
                    notes: "Bluetooth LE connection. SDK available via Canon developer program."
                ),
                msrp: "$149",
                notes: "Square format only. Novel for Instagram-style booth prints."
            ),
        ]
    }

    // MARK: - Sinfonia (formerly Shinko/Ciaat)

    static var sinfoniaPrinters: [PrinterSpec] {
        [
            PrinterSpec(
                model: "CS2",
                vendor: .sinfonia,
                type: .dyeSublimation,
                mediaSizes: ["4x6", "5x7", "6x8", "6x9", "2x6 strip"],
                maxPrintsPerRoll: 600,
                printSpeed4x6Seconds: 7.5,
                resolution: 300,
                connectionMethods: [.usbToHostPC],
                airPrintSupport: .viaHostPC,
                vendorSDK: nil,
                msrp: "$1,050",
                notes: "600 prints per roll. Fast. USB only. No iOS SDK."
            ),
        ]
    }
}

// MARK: - Printer Spec Data Model

public struct PrinterSpec: Sendable {
    public let model: String
    public let vendor: PhotoBoothPrinterVendor
    public let type: PrinterType
    public let mediaSizes: [String]
    public let maxPrintsPerRoll: Int
    public let printSpeed4x6Seconds: TimeInterval
    public let resolution: Int                          // DPI
    public let connectionMethods: [ConnectionMethod]
    public let airPrintSupport: AirPrintLevel
    public let vendorSDK: VendorSDKInfo?
    public let msrp: String
    public let notes: String

    public enum PrinterType: String, Sendable {
        case dyeSublimation = "Dye-Sublimation"
        case thermal = "Thermal"
        case inkjet = "Inkjet"
    }

    public enum ConnectionMethod: String, Sendable {
        case wifi = "WiFi (Infrastructure)"
        case wifiDirect = "WiFi Direct"
        case wifiViaWPS1 = "WiFi via DNP WPS-1"
        case usbDirect = "USB Direct to iPad"
        case usbToHostPC = "USB to Host Mac/PC"
        case bluetooth = "Bluetooth"
        case ethernet = "Ethernet"
    }

    public enum AirPrintLevel: String, Sendable {
        case native = "Native (built-in)"
        case viaAccessory = "Via wireless accessory (WPS-1, Silex, etc.)"
        case viaHostPC = "Via host Mac/PC printer sharing"
        case notSupported = "Not supported"
    }

    public struct VendorSDKInfo: Sendable {
        public let name: String
        public let platform: SDKPlatform
        public let notes: String

        public enum SDKPlatform: String, Sendable {
            case iOSOnly = "iOS only"
            case androidOnly = "Android only"
            case iOSAndAndroid = "iOS and Android"
            case windowsOnly = "Windows only"
            case macAndWindows = "macOS and Windows"
        }

        public init(name: String, platform: SDKPlatform, notes: String) {
            self.name = name
            self.platform = platform
            self.notes = notes
        }
    }
}
