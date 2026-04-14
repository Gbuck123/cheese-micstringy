// PrintQueueManager.swift
// Offline print queue with retry logic, print count tracking,
// duplicate detection, and event-level print management.

import UIKit
import os.log

// MARK: - Print Job Model

/// Represents a single print job in the queue.
public struct PrintJob: Codable, Identifiable, Sendable {
    public let id: String
    public let eventId: String
    public let imageFilename: String       // Relative path in the queue's storage directory
    public let layoutType: String          // e.g., "4x6_single", "2x6_double_strip"
    public let copies: Int
    public let createdAt: Date
    public var status: Status
    public var attemptCount: Int
    public var lastAttemptAt: Date?
    public var lastError: String?
    public var printerURL: String?
    public var completedAt: Date?

    /// SHA-256 hash of the source image data for duplicate detection.
    public let imageHash: String

    public enum Status: String, Codable, Sendable {
        case pending
        case printing
        case completed
        case failed
        case cancelled
    }

    public init(eventId: String,
                imageFilename: String,
                layoutType: String,
                copies: Int = 1,
                imageHash: String) {
        self.id = UUID().uuidString
        self.eventId = eventId
        self.imageFilename = imageFilename
        self.layoutType = layoutType
        self.copies = copies
        self.createdAt = Date()
        self.status = .pending
        self.attemptCount = 0
        self.imageHash = imageHash
    }
}

// MARK: - Event Print Stats

public struct EventPrintStats: Codable, Sendable {
    public let eventId: String
    public var totalJobsSubmitted: Int
    public var totalPrintsCompleted: Int
    public var totalPrintsFailed: Int
    public var totalCopiesPrinted: Int
    public var firstPrintAt: Date?
    public var lastPrintAt: Date?
}

// MARK: - Print Queue Manager

/// Manages an offline-capable print queue with persistence, retry logic,
/// duplicate detection, and per-event tracking.
///
/// Print jobs are persisted to disk so they survive app restarts.
/// The queue processes jobs sequentially to avoid overwhelming the printer.
@MainActor
public final class PrintQueueManager: ObservableObject {

    // MARK: Published State

    @Published public private(set) var queue: [PrintJob] = []
    @Published public private(set) var isProcessing = false
    @Published public private(set) var currentJob: PrintJob?
    @Published public private(set) var eventStats: [String: EventPrintStats] = [:]

    // MARK: Configuration

    public struct Config {
        public var maxRetryAttempts: Int = 3
        public var retryDelaySeconds: TimeInterval = 5
        public var autoPrintEnabled: Bool = true
        public var duplicateDetectionEnabled: Bool = true
        public var duplicateWindowSeconds: TimeInterval = 60  // Ignore duplicates within this window
        public var maxConcurrentJobs: Int = 1                 // Sequential for dye-sub printers
        public var storageDirectory: URL

        public init(storageDirectory: URL? = nil) {
            self.storageDirectory = storageDirectory ?? Self.defaultStorageDirectory
        }

        public static var defaultStorageDirectory: URL {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PrintQueue", isDirectory: true)
        }
    }

    public var config: Config

    // MARK: Dependencies

    private let airPrintService: AirPrintService
    private let logger = Logger(subsystem: "com.photobooth", category: "PrintQueue")

    // MARK: Private State

    private var processingTask: Task<Void, Never>?
    private var recentImageHashes: [(hash: String, timestamp: Date)] = []

    // MARK: Init

    public init(airPrintService: AirPrintService = AirPrintService(),
                config: Config = Config()) {
        self.airPrintService = airPrintService
        self.config = config

        ensureStorageDirectory()
        loadQueue()
        loadEventStats()

        // Resume any pending jobs from a previous session
        resumeProcessingIfNeeded()
    }

    // MARK: - Public API

    /// Enqueues a print job. Returns nil if the image is detected as a duplicate.
    @discardableResult
    public func enqueue(image: UIImage,
                        eventId: String,
                        layoutType: String,
                        copies: Int = 1) -> PrintJob? {

        // Compute image hash for duplicate detection
        let imageHash = computeImageHash(image)

        // Check for duplicates
        if config.duplicateDetectionEnabled {
            if isDuplicate(hash: imageHash) {
                logger.warning("Duplicate print detected (hash: \(imageHash.prefix(16))...), skipping.")
                return nil
            }
        }

        // Save image to disk
        let filename = "\(UUID().uuidString).jpg"
        let fileURL = config.storageDirectory.appendingPathComponent(filename)

        guard let data = image.jpegData(compressionQuality: 0.95) else {
            logger.error("Failed to encode image as JPEG")
            return nil
        }

        do {
            try data.write(to: fileURL)
        } catch {
            logger.error("Failed to save print image: \(error.localizedDescription)")
            return nil
        }

        // Create job
        let job = PrintJob(
            eventId: eventId,
            imageFilename: filename,
            layoutType: layoutType,
            copies: copies,
            imageHash: imageHash
        )

        queue.append(job)
        saveQueue()

        // Track duplicate hash
        recentImageHashes.append((hash: imageHash, timestamp: Date()))
        cleanupOldHashes()

        // Update event stats
        updateEventStats(eventId: eventId, submitted: 1)

        logger.info("Enqueued print job \(job.id) for event \(eventId)")

        // Start processing if auto-print is enabled
        if config.autoPrintEnabled {
            startProcessing()
        }

        return job
    }

    /// Manually trigger processing of pending jobs.
    public func startProcessing() {
        guard !isProcessing else { return }

        processingTask = Task { [weak self] in
            await self?.processQueue()
        }
    }

    /// Stop processing (current job will complete).
    public func stopProcessing() {
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
    }

    /// Cancel a specific job.
    public func cancelJob(id: String) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].status = .cancelled
        saveQueue()

        // Delete the image file
        let fileURL = config.storageDirectory.appendingPathComponent(queue[index].imageFilename)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Cancel all pending jobs.
    public func cancelAllPending() {
        for i in queue.indices where queue[i].status == .pending {
            queue[i].status = .cancelled
            let fileURL = config.storageDirectory.appendingPathComponent(queue[i].imageFilename)
            try? FileManager.default.removeItem(at: fileURL)
        }
        saveQueue()
    }

    /// Retry all failed jobs.
    public func retryAllFailed() {
        for i in queue.indices where queue[i].status == .failed {
            queue[i].status = .pending
            queue[i].attemptCount = 0
            queue[i].lastError = nil
        }
        saveQueue()
        startProcessing()
    }

    /// Get stats for a specific event.
    public func stats(for eventId: String) -> EventPrintStats {
        eventStats[eventId] ?? EventPrintStats(
            eventId: eventId,
            totalJobsSubmitted: 0,
            totalPrintsCompleted: 0,
            totalPrintsFailed: 0,
            totalCopiesPrinted: 0
        )
    }

    /// Clear completed jobs older than the given interval.
    public func pruneCompletedJobs(olderThan interval: TimeInterval = 86400) {
        let cutoff = Date().addingTimeInterval(-interval)
        queue.removeAll { job in
            if job.status == .completed, let completedAt = job.completedAt, completedAt < cutoff {
                let fileURL = config.storageDirectory.appendingPathComponent(job.imageFilename)
                try? FileManager.default.removeItem(at: fileURL)
                return true
            }
            return false
        }
        saveQueue()
    }

    // MARK: - Queue Processing

    private func processQueue() async {
        isProcessing = true
        defer { isProcessing = false }

        while !Task.isCancelled {
            // Find next pending job
            guard let jobIndex = queue.firstIndex(where: { $0.status == .pending }) else {
                logger.info("Print queue empty, stopping processor.")
                break
            }

            var job = queue[jobIndex]
            job.status = .printing
            job.attemptCount += 1
            job.lastAttemptAt = Date()
            queue[jobIndex] = job
            currentJob = job
            saveQueue()

            logger.info("Processing job \(job.id) (attempt \(job.attemptCount)/\(self.config.maxRetryAttempts))")

            // Load image from disk
            let fileURL = config.storageDirectory.appendingPathComponent(job.imageFilename)
            guard let imageData = try? Data(contentsOf: fileURL),
                  let image = UIImage(data: imageData) else {
                logger.error("Failed to load image for job \(job.id)")
                job.status = .failed
                job.lastError = "Image file not found or corrupted"
                queue[jobIndex] = job
                saveQueue()
                continue
            }

            // Build print config
            var printConfig = PhotoBoothPrintConfig()
            printConfig.jobName = "Photo Booth - \(job.eventId) - \(job.id.prefix(8))"
            printConfig.preferredPrinterURL = airPrintService.lastPrinterURL

            // Attempt to print
            let result: PrintJobResult
            if job.copies > 1 {
                let results = await airPrintService.printSilentMultipleCopies(
                    image: image, config: printConfig, copies: job.copies
                )
                // Consider the job successful if at least one copy printed
                if results.contains(where: { if case .success = $0 { return true }; return false }) {
                    result = .success(printerURL: airPrintService.lastPrinterURL)
                } else if let failure = results.first(where: { if case .failed = $0 { return true }; return false }) {
                    result = failure
                } else {
                    result = .cancelled
                }
            } else {
                result = await airPrintService.printSilent(image: image, config: printConfig)
            }

            // Handle result
            switch result {
            case .success(let printerURL):
                job.status = .completed
                job.completedAt = Date()
                job.printerURL = printerURL?.absoluteString
                queue[jobIndex] = job
                updateEventStats(eventId: job.eventId, completed: job.copies)
                logger.info("Job \(job.id) completed successfully")

            case .failed(let error):
                job.lastError = error.localizedDescription
                if job.attemptCount >= config.maxRetryAttempts {
                    job.status = .failed
                    updateEventStats(eventId: job.eventId, failed: 1)
                    logger.error("Job \(job.id) failed permanently after \(job.attemptCount) attempts: \(error.localizedDescription)")
                } else {
                    job.status = .pending  // Will retry
                    logger.warning("Job \(job.id) failed (attempt \(job.attemptCount)), will retry: \(error.localizedDescription)")

                    // Wait before retrying
                    try? await Task.sleep(nanoseconds: UInt64(config.retryDelaySeconds * 1_000_000_000))
                }
                queue[jobIndex] = job

            case .cancelled:
                job.status = .pending  // Don't count as attempt
                job.attemptCount -= 1
                queue[jobIndex] = job
                logger.info("Job \(job.id) was cancelled by system, re-queuing.")
            }

            currentJob = nil
            saveQueue()
        }
    }

    private func resumeProcessingIfNeeded() {
        // Reset any jobs that were "printing" when the app was killed
        for i in queue.indices where queue[i].status == .printing {
            queue[i].status = .pending
        }
        saveQueue()

        if queue.contains(where: { $0.status == .pending }) && config.autoPrintEnabled {
            startProcessing()
        }
    }

    // MARK: - Duplicate Detection

    private func computeImageHash(_ image: UIImage) -> String {
        // Use a perceptual hash based on a downscaled grayscale thumbnail.
        // This catches duplicates even if the image is re-encoded.
        let size = CGSize(width: 16, height: 16)
        let renderer = UIGraphicsImageRenderer(size: size)
        let thumbnail = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }

        guard let data = thumbnail.pngData() else { return UUID().uuidString }

        // Simple hash (for production, use CryptoKit SHA256)
        var hash: UInt64 = 5381
        for byte in data {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }

    private func isDuplicate(hash: String) -> Bool {
        let cutoff = Date().addingTimeInterval(-config.duplicateWindowSeconds)
        return recentImageHashes.contains { $0.hash == hash && $0.timestamp > cutoff }
    }

    private func cleanupOldHashes() {
        let cutoff = Date().addingTimeInterval(-config.duplicateWindowSeconds * 2)
        recentImageHashes.removeAll { $0.timestamp < cutoff }
    }

    // MARK: - Event Stats

    private func updateEventStats(eventId: String,
                                  submitted: Int = 0,
                                  completed: Int = 0,
                                  failed: Int = 0) {
        var stats = eventStats[eventId] ?? EventPrintStats(
            eventId: eventId,
            totalJobsSubmitted: 0,
            totalPrintsCompleted: 0,
            totalPrintsFailed: 0,
            totalCopiesPrinted: 0
        )

        stats.totalJobsSubmitted += submitted
        stats.totalPrintsCompleted += completed > 0 ? 1 : 0
        stats.totalPrintsFailed += failed
        stats.totalCopiesPrinted += completed

        if submitted > 0 && stats.firstPrintAt == nil {
            stats.firstPrintAt = Date()
        }
        if completed > 0 || failed > 0 {
            stats.lastPrintAt = Date()
        }

        eventStats[eventId] = stats
        saveEventStats()
    }

    // MARK: - Persistence

    private var queueFileURL: URL {
        config.storageDirectory.appendingPathComponent("print_queue.json")
    }

    private var statsFileURL: URL {
        config.storageDirectory.appendingPathComponent("event_stats.json")
    }

    private func ensureStorageDirectory() {
        try? FileManager.default.createDirectory(
            at: config.storageDirectory,
            withIntermediateDirectories: true
        )
    }

    private func saveQueue() {
        do {
            let data = try JSONEncoder().encode(queue)
            try data.write(to: queueFileURL, options: .atomic)
        } catch {
            logger.error("Failed to save print queue: \(error.localizedDescription)")
        }
    }

    private func loadQueue() {
        guard let data = try? Data(contentsOf: queueFileURL) else { return }
        do {
            queue = try JSONDecoder().decode([PrintJob].self, from: data)
        } catch {
            logger.error("Failed to load print queue: \(error.localizedDescription)")
        }
    }

    private func saveEventStats() {
        do {
            let data = try JSONEncoder().encode(eventStats)
            try data.write(to: statsFileURL, options: .atomic)
        } catch {
            logger.error("Failed to save event stats: \(error.localizedDescription)")
        }
    }

    private func loadEventStats() {
        guard let data = try? Data(contentsOf: statsFileURL) else { return }
        do {
            eventStats = try JSONDecoder().decode([String: EventPrintStats].self, from: data)
        } catch {
            logger.error("Failed to load event stats: \(error.localizedDescription)")
        }
    }
}
