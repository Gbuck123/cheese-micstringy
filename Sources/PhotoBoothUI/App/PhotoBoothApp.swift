// PhotoBoothApp.swift
// Main entry point for the Photo Booth iPad application.

import SwiftUI

/// The main photo booth application. Configures the scene with kiosk-mode
/// settings and creates the root navigation container.
@main
struct PhotoBoothApp: App {

    @State private var session: BoothSession
    @State private var kioskManager = KioskManager()
    @State private var selectedLanguage: String = "en"

    init() {
        let config = BoothConfiguration()
        // In production, load config from server/JSON here:
        // config.loadFromEvent(eventID: "...")
        let session = BoothSession(config: config)
        self._session = State(initialValue: session)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                BoothNavigationContainer(session: session)
                    .environment(session)
                    .environment(kioskManager)
                    .kioskDynamicType()

                // Kiosk warning overlay (always on top)
                KioskWarningOverlay(kioskManager: kioskManager)
                    .allowsHitTesting(false)
            }
            .onAppear {
                configureKiosk()
            }
            .onDisappear {
                kioskManager.stopMonitoring()
            }
        }
    }

    private func configureKiosk() {
        kioskManager.session = session
        kioskManager.startMonitoring()

        if session.config.guidedAccessEnabled {
            kioskManager.requestGuidedAccess(enabled: true)
        }

        // Pre-warm haptics and sounds.
        _ = HapticEngine.shared
        SoundManager.shared.preloadAll()
    }
}
