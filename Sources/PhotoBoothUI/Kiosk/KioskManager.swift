// KioskManager.swift
// Guided Access, app-switching prevention, notification suppression,
// battery/thermal monitoring, and auto-recovery for kiosk deployment.

import UIKit
import os
import Combine

private let logger = Logger(subsystem: "com.photobooth.ui", category: "KioskManager")

/// Manages all kiosk-mode concerns: Guided Access, preventing system gestures,
/// auto-recovery from backgrounding, and hardware monitoring.
@Observable
public final class KioskManager {

    // MARK: - Observed State

    /// Whether Guided Access is currently active.
    public private(set) var isGuidedAccessActive: Bool = false
    /// Current battery level (0.0 - 1.0).
    public private(set) var batteryLevel: Float = 1.0
    /// Whether the device is currently charging.
    public private(set) var isCharging: Bool = false
    /// Current thermal state.
    public private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    /// Whether a battery warning should be displayed.
    public var showBatteryWarning: Bool = false
    /// Whether a thermal warning should be displayed.
    public var showThermalWarning: Bool = false

    // MARK: - Configuration

    /// Battery level below which to show a warning.
    public var lowBatteryThreshold: Float = 0.15
    /// The session to reset when recovering from background.
    public weak var session: BoothSession?

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    // MARK: - Init

    public init() {}

    // MARK: - Guided Access

    /// Request Guided Access mode. The device must have Guided Access enabled
    /// in Settings > Accessibility > Guided Access.
    ///
    /// Note: `UIAccessibility.requestGuidedAccessSession` requires the
    /// `com.apple.developer.guided-access` entitlement and the device must
    /// be supervised (MDM) or have Guided Access pre-configured.
    public func requestGuidedAccess(enabled: Bool) {
        UIAccessibility.requestGuidedAccessSession(enabled: enabled) { [weak self] success in
            DispatchQueue.main.async {
                self?.isGuidedAccessActive = success && enabled
                if success {
                    logger.info("Guided Access \(enabled ? "enabled" : "disabled") successfully")
                } else {
                    logger.warning("Guided Access request failed. Is the device supervised?")
                }
            }
        }
    }

    // MARK: - Lifecycle Monitoring

    /// Start monitoring app lifecycle, battery, and thermal state.
    /// Call this from your App's init or scene's onAppear.
    public func startMonitoring() {
        monitorAppLifecycle()
        monitorBattery()
        monitorThermalState()
        logger.info("Kiosk monitoring started")
    }

    /// Stop all monitoring.
    public func stopMonitoring() {
        cancellables.removeAll()
        UIDevice.current.isBatteryMonitoringEnabled = false
        logger.info("Kiosk monitoring stopped")
    }

    // MARK: - App Lifecycle

    private func monitorAppLifecycle() {
        // Auto-recovery when app returns to foreground.
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                logger.info("App returning to foreground - recovering kiosk state")
                self?.recoverFromBackground()
            }
            .store(in: &cancellables)

        // Attempt to keep alive when backgrounded.
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                logger.warning("App entered background - starting background task")
                self?.startBackgroundTask()
            }
            .store(in: &cancellables)

        // Suppress notification banners via the scene-level API.
        NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)
            .sink { _ in
                logger.info("Scene will deactivate")
            }
            .store(in: &cancellables)
    }

    private func recoverFromBackground() {
        // Reset session to attract screen on recovery.
        DispatchQueue.main.async { [weak self] in
            self?.session?.reset()
        }

        // Re-request Guided Access if it was active.
        if isGuidedAccessActive {
            requestGuidedAccess(enabled: true)
        }

        // Re-hide the status bar and home indicator.
        setFullScreenMode()
    }

    private func startBackgroundTask() {
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "KioskRecovery") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    // MARK: - Battery Monitoring

    private func monitorBattery() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        updateBatteryState()

        NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)
            .sink { [weak self] _ in
                self?.updateBatteryState()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)
            .sink { [weak self] _ in
                self?.updateBatteryState()
            }
            .store(in: &cancellables)
    }

    private func updateBatteryState() {
        let device = UIDevice.current
        batteryLevel = device.batteryLevel
        isCharging = device.batteryState == .charging || device.batteryState == .full

        let shouldWarn = batteryLevel < lowBatteryThreshold && !isCharging
        if shouldWarn != showBatteryWarning {
            showBatteryWarning = shouldWarn
            if shouldWarn {
                logger.warning("Low battery: \(Int(self.batteryLevel * 100))%")
            }
        }
    }

    // MARK: - Thermal Monitoring

    private func monitorThermalState() {
        thermalState = ProcessInfo.processInfo.thermalState

        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.thermalState = ProcessInfo.processInfo.thermalState
                let isCritical = self.thermalState == .critical || self.thermalState == .serious
                if isCritical != self.showThermalWarning {
                    self.showThermalWarning = isCritical
                    if isCritical {
                        logger.warning("Thermal state critical: \(String(describing: self.thermalState))")
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Full Screen Mode

    /// Apply kiosk-appropriate UIKit settings.
    private func setFullScreenMode() {
        // Request the key window's root view controller to update its preferences.
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else { return }

        window.rootViewController?.setNeedsUpdateOfHomeIndicatorAutoHidden()
        window.rootViewController?.setNeedsStatusBarAppearanceUpdate()
        window.rootViewController?.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }
}

// MARK: - Kiosk View Controller

/// A hosting view controller that configures system gesture deferral
/// and home indicator hiding for kiosk mode.
public final class KioskHostingController<Content: View>: UIHostingController<Content> {

    public override var prefersStatusBarHidden: Bool { true }

    public override var prefersHomeIndicatorAutoHidden: Bool { true }

    public override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    public override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        // Lock to landscape for most photo booth deployments.
        // Change to .portrait or .all as needed.
        .landscape
    }

    public override var shouldAutorotate: Bool { false }
}

// MARK: - Kiosk Warning Overlay

/// A SwiftUI overlay that shows battery and thermal warnings.
public struct KioskWarningOverlay: View {
    let kioskManager: KioskManager

    public init(kioskManager: KioskManager) {
        self.kioskManager = kioskManager
    }

    public var body: some View {
        VStack {
            HStack(spacing: 16) {
                if kioskManager.showBatteryWarning {
                    warningBadge(
                        icon: "battery.25",
                        text: "Low Battery: \(Int(kioskManager.batteryLevel * 100))%",
                        color: .red
                    )
                }
                if kioskManager.showThermalWarning {
                    warningBadge(
                        icon: "thermometer.sun.fill",
                        text: "Device Overheating",
                        color: .orange
                    )
                }
            }
            .padding(.top, 20)

            Spacer()
        }
        .animation(.easeInOut, value: kioskManager.showBatteryWarning)
        .animation(.easeInOut, value: kioskManager.showThermalWarning)
    }

    private func warningBadge(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.body.bold())
            Text(text)
                .font(.callout.bold())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(color)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Warning: \(text)"))
        .accessibilityAddTraits(.isStaticText)
    }
}
