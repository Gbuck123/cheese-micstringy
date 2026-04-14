// AirPrintService.swift
// Complete AirPrint integration for photo booth printing.
// Supports both interactive (UI) and silent (auto-print) workflows.

import UIKit

// MARK: - Print Configuration

/// Encapsulates all print settings for a photo booth print job.
public struct PhotoBoothPrintConfig {

    public enum PaperSize: String, CaseIterable, Sendable {
        case fourBySix = "4x6"
        case twoBySix = "2x6"      // Requires 4x6 media with cut
        case fiveBySeven = "5x7"
        case eightByTen = "8x10"
        case letter = "Letter"

        /// Best-fit UIPrintPaper matching for this size.
        /// Used when AirPrint doesn't have exact media match.
        public var approximateSize: CGSize {
            switch self {
            case .fourBySix:    return CGSize(width: 4 * 72, height: 6 * 72)     // 288 x 432 pts
            case .twoBySix:     return CGSize(width: 4 * 72, height: 6 * 72)     // Printed on 4x6 media
            case .fiveBySeven:  return CGSize(width: 5 * 72, height: 7 * 72)     // 360 x 504 pts
            case .eightByTen:   return CGSize(width: 8 * 72, height: 10 * 72)    // 576 x 720 pts
            case .letter:       return CGSize(width: 8.5 * 72, height: 11 * 72)  // 612 x 792 pts
            }
        }
    }

    public var paperSize: PaperSize
    public var numberOfCopies: Int
    public var preferredPrinterURL: URL?    // Remembered printer
    public var jobName: String
    public var showsPageRange: Bool
    public var orientation: UIPrintInfo.Orientation

    public init(paperSize: PaperSize = .fourBySix,
                numberOfCopies: Int = 1,
                preferredPrinterURL: URL? = nil,
                jobName: String = "Photo Booth Print",
                showsPageRange: Bool = false,
                orientation: UIPrintInfo.Orientation = .portrait) {
        self.paperSize = paperSize
        self.numberOfCopies = numberOfCopies
        self.preferredPrinterURL = preferredPrinterURL
        self.jobName = jobName
        self.showsPageRange = showsPageRange
        self.orientation = orientation
    }
}

// MARK: - Print Job Result

public enum PrintJobResult: Sendable {
    case success(printerURL: URL?)
    case cancelled
    case failed(Error)
}

// MARK: - AirPrint Service

/// Manages AirPrint integration with support for both interactive and silent printing.
///
/// Usage:
/// ```swift
/// let service = AirPrintService()
///
/// // Interactive (shows system print dialog):
/// let result = await service.printInteractive(image: photo, config: config, from: viewController)
///
/// // Silent auto-print (no UI, requires known printer):
/// let result = await service.printSilent(image: photo, config: config)
/// ```
public final class AirPrintService: NSObject {

    // MARK: Properties

    /// The last successfully used printer URL, persisted across sessions.
    public var lastPrinterURL: URL? {
        get { UserDefaults.standard.url(forKey: "PhotoBooth.lastPrinterURL") }
        set { UserDefaults.standard.set(newValue, forKey: "PhotoBooth.lastPrinterURL") }
    }

    /// The last used printer's display name.
    public var lastPrinterName: String? {
        get { UserDefaults.standard.string(forKey: "PhotoBooth.lastPrinterName") }
        set { UserDefaults.standard.set(newValue, forKey: "PhotoBooth.lastPrinterName") }
    }

    private var printCompletionHandler: ((PrintJobResult) -> Void)?

    // MARK: - Interactive Printing (with system UI)

    /// Presents the system print interaction controller and returns the result.
    /// This shows the standard iOS print dialog where the user can select a printer.
    @MainActor
    public func printInteractive(image: UIImage,
                                 config: PhotoBoothPrintConfig,
                                 from viewController: UIViewController) async -> PrintJobResult {
        return await withCheckedContinuation { continuation in
            let controller = UIPrintInteractionController.shared

            // Configure print info
            let printInfo = UIPrintInfo(dictionary: nil)
            printInfo.jobName = config.jobName
            printInfo.outputType = .photo         // Critical: tells AirPrint to use photo quality
            printInfo.orientation = config.orientation
            printInfo.duplex = .none              // Photo prints are single-sided
            controller.printInfo = printInfo

            // Set the image to print
            controller.printingItem = image

            // Number of copies
            // Note: UIPrintInteractionController doesn't directly expose copy count in code;
            // the user sets it in the dialog. For auto-print, see printSilent().

            // Paper size selection
            controller.showsNumberOfCopies = true
            controller.showsPaperSelectionForLoadedPapers = true
            controller.showsPageRange = config.showsPageRange

            // Set preferred printer if we have one from a previous session
            if let printerURL = config.preferredPrinterURL ?? lastPrinterURL {
                controller.printPaper = nil  // Let system match
                // UIPrintInteractionController remembers the last printer automatically,
                // but we can set it explicitly via the picker
                let printer = UIPrinter(url: printerURL)
                controller.print(to: printer, completionHandler: { [weak self] _, completed, error in
                    self?.handleCompletion(completed: completed, error: error,
                                           printerURL: printerURL,
                                           continuation: continuation)
                })
                return
            }

            // Present the print dialog
            controller.present(animated: true) { [weak self] _, completed, error in
                // Extract printer URL from the controller after user selects
                let printerURL = controller.printInfo?.printerID.flatMap { URL(string: $0) }
                self?.handleCompletion(completed: completed, error: error,
                                       printerURL: printerURL,
                                       continuation: continuation)
            }
        }
    }

    /// Overload for presenting from a bar button item (iPad popover).
    @MainActor
    public func printInteractive(image: UIImage,
                                 config: PhotoBoothPrintConfig,
                                 from barButtonItem: UIBarButtonItem) async -> PrintJobResult {
        return await withCheckedContinuation { continuation in
            let controller = UIPrintInteractionController.shared

            let printInfo = UIPrintInfo(dictionary: nil)
            printInfo.jobName = config.jobName
            printInfo.outputType = .photo
            printInfo.orientation = config.orientation
            printInfo.duplex = .none
            controller.printInfo = printInfo
            controller.printingItem = image
            controller.showsNumberOfCopies = true
            controller.showsPaperSelectionForLoadedPapers = true

            controller.present(from: barButtonItem, animated: true) { [weak self] _, completed, error in
                let printerURL = controller.printInfo?.printerID.flatMap { URL(string: $0) }
                self?.handleCompletion(completed: completed, error: error,
                                       printerURL: printerURL,
                                       continuation: continuation)
            }
        }
    }

    // MARK: - Silent Auto-Print (No UI)

    /// Prints directly to a known printer without showing any UI.
    /// This is the key method for photo booth auto-print after capture.
    ///
    /// - Important: You must have a valid printer URL. Call `discoverPrinters()` first
    ///   or use the URL from a previous interactive print.
    @MainActor
    public func printSilent(image: UIImage,
                            config: PhotoBoothPrintConfig) async -> PrintJobResult {
        guard let printerURL = config.preferredPrinterURL ?? lastPrinterURL else {
            return .failed(PrintError.noPrinterConfigured)
        }

        return await withCheckedContinuation { continuation in
            let controller = UIPrintInteractionController.shared

            let printInfo = UIPrintInfo(dictionary: nil)
            printInfo.jobName = config.jobName
            printInfo.outputType = .photo
            printInfo.orientation = config.orientation
            printInfo.duplex = .none
            controller.printInfo = printInfo
            controller.printingItem = image

            let printer = UIPrinter(url: printerURL)

            // Print directly to the printer, no UI
            controller.print(to: printer, completionHandler: { [weak self] _, completed, error in
                self?.handleCompletion(completed: completed, error: error,
                                       printerURL: printerURL,
                                       continuation: continuation)
            })
        }
    }

    /// Prints multiple copies silently by submitting sequential print jobs.
    @MainActor
    public func printSilentMultipleCopies(image: UIImage,
                                          config: PhotoBoothPrintConfig,
                                          copies: Int) async -> [PrintJobResult] {
        var results: [PrintJobResult] = []
        for i in 0..<copies {
            var jobConfig = config
            jobConfig.jobName = "\(config.jobName) (\(i + 1)/\(copies))"
            let result = await printSilent(image: image, config: jobConfig)
            results.append(result)

            // Small delay between jobs to avoid overwhelming the printer spooler
            if i < copies - 1 {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            }
        }
        return results
    }

    // MARK: - Printer Discovery

    /// Discovers available AirPrint printers on the network.
    /// Uses UIPrinterPickerController for system-level discovery.
    @MainActor
    public func showPrinterPicker(from viewController: UIViewController) async -> UIPrinter? {
        return await withCheckedContinuation { continuation in
            let picker = UIPrinterPickerController(initiallySelectedPrinter: nil)

            picker.present(from: CGRect(x: 0, y: 0, width: 300, height: 300),
                           in: viewController.view,
                           animated: true) { [weak self] controller, userDidSelect, error in
                if userDidSelect, let printer = controller.selectedPrinter {
                    self?.lastPrinterURL = printer.url
                    self?.lastPrinterName = printer.displayName
                    continuation.resume(returning: printer)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Validates that a previously saved printer is still reachable.
    public func validatePrinter(url: URL) async -> (reachable: Bool, printer: UIPrinter) {
        let printer = UIPrinter(url: url)

        return await withCheckedContinuation { continuation in
            printer.contactPrinter { available in
                continuation.resume(returning: (available, printer))
            }
        }
    }

    // MARK: - Print Data (for Custom Page Renderers)

    /// Prints using a UIPrintPageRenderer for precise layout control.
    /// Use this when you need exact margins and DPI control.
    @MainActor
    public func printWithRenderer(renderer: UIPrintPageRenderer,
                                  config: PhotoBoothPrintConfig) async -> PrintJobResult {
        guard let printerURL = config.preferredPrinterURL ?? lastPrinterURL else {
            return .failed(PrintError.noPrinterConfigured)
        }

        return await withCheckedContinuation { continuation in
            let controller = UIPrintInteractionController.shared

            let printInfo = UIPrintInfo(dictionary: nil)
            printInfo.jobName = config.jobName
            printInfo.outputType = .photo
            printInfo.orientation = config.orientation
            controller.printInfo = printInfo
            controller.printPageRenderer = renderer

            let printer = UIPrinter(url: printerURL)
            controller.print(to: printer) { [weak self] _, completed, error in
                self?.handleCompletion(completed: completed, error: error,
                                       printerURL: printerURL,
                                       continuation: continuation)
            }
        }
    }

    // MARK: - Completion Handling

    private func handleCompletion(completed: Bool,
                                  error: Error?,
                                  printerURL: URL?,
                                  continuation: CheckedContinuation<PrintJobResult, Never>) {
        if let error = error {
            continuation.resume(returning: .failed(error))
        } else if completed {
            // Remember successful printer
            if let url = printerURL {
                lastPrinterURL = url
            }
            continuation.resume(returning: .success(printerURL: printerURL))
        } else {
            continuation.resume(returning: .cancelled)
        }
    }
}

// MARK: - Custom Page Renderer for Precise Print Layout

/// A page renderer that draws a photo with exact margins and scaling.
/// Use this when you need pixel-perfect control over the printed output.
public final class PhotoBoothPageRenderer: UIPrintPageRenderer {

    private let image: UIImage
    private let targetPaperSize: PhotoBoothPrintConfig.PaperSize
    private let printDPI: CGFloat

    /// Margins in inches.
    public var marginInches: UIEdgeInsets = .zero

    public init(image: UIImage,
                paperSize: PhotoBoothPrintConfig.PaperSize,
                dpi: CGFloat = 300,
                margins: UIEdgeInsets = .zero) {
        self.image = image
        self.targetPaperSize = paperSize
        self.printDPI = dpi
        self.marginInches = margins
        super.init()
    }

    override public var numberOfPages: Int { 1 }

    override public func drawPage(at pageIndex: Int, in printableRect: CGRect) {
        // The printableRect is in points (72 DPI).
        // We draw the image to fill this rect, maintaining aspect ratio.

        let imageAspect = image.size.width / image.size.height
        let rectAspect = printableRect.width / printableRect.height

        var drawRect = printableRect

        if imageAspect > rectAspect {
            // Image is wider: match width, crop height
            let scaledHeight = printableRect.width / imageAspect
            drawRect = CGRect(
                x: printableRect.origin.x,
                y: printableRect.origin.y + (printableRect.height - scaledHeight) / 2,
                width: printableRect.width,
                height: scaledHeight
            )
        } else {
            // Image is taller: match height, crop width
            let scaledWidth = printableRect.height * imageAspect
            drawRect = CGRect(
                x: printableRect.origin.x + (printableRect.width - scaledWidth) / 2,
                y: printableRect.origin.y,
                width: scaledWidth,
                height: printableRect.height
            )
        }

        image.draw(in: drawRect)
    }

    override public func drawPrintFormatter(_ printFormatter: UIPrintFormatter,
                                            forPageAt pageIndex: Int) {
        // Not using print formatters; we draw directly.
    }
}

// MARK: - Errors

public enum PrintError: LocalizedError {
    case noPrinterConfigured
    case printerUnreachable(URL)
    case printJobFailed(String)
    case imageRenderingFailed
    case unsupportedPaperSize

    public var errorDescription: String? {
        switch self {
        case .noPrinterConfigured:
            return "No printer is configured. Please select a printer first."
        case .printerUnreachable(let url):
            return "Printer at \(url.absoluteString) is not reachable."
        case .printJobFailed(let reason):
            return "Print job failed: \(reason)"
        case .imageRenderingFailed:
            return "Failed to render image for printing."
        case .unsupportedPaperSize:
            return "The selected paper size is not supported by this printer."
        }
    }
}
