import UIKit
import SwiftUI
import BackgroundTasks

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }

        // NOTE: Do NOT call StartRelayC here directly.
        // RelayProcessManager.startRelay() is called from ContentView.onAppear,
        // which also updates all state flags (isRunning, isBooting, etc.).
        // Calling StartRelayC() directly here bypasses that state management,
        // leaving relayManager.isRunning = false forever, which causes the
        // ViewerView notes fetch guard to always bail.

        let window = UIWindow(windowScene: windowScene)
        
        let configService = ConfigService.shared
        let relayManager = RelayProcessManager.shared
        let nostrService = NostrService.shared
        let statsService = StatsService.shared
        
        let contentView = ContentView()
            .environmentObject(configService)
            .environmentObject(relayManager)
            .environmentObject(nostrService)
            .environmentObject(statsService)
            .environmentObject(AppState.shared)
        
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: contentView)
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // RelayProcessManager.shared.stopRelay() is the proper way to stop,
        // but on disconnect we can call StopRelayC directly since the app is going away.
        StopRelayC()
    }

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    func sceneDidBecomeActive(_ scene: UIScene) {
        // End the background task if the user has returned to the app.
        endBackgroundTask()

        // Clear app badge and reset server-side badge counter
        Task { @MainActor in
            PushNotificationService.shared.clearBadge()
        }
    }

    func sceneWillResignActive(_ scene: UIScene) {
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Reconnect NIP-46 remote signer if configured
        if ConfigService.shared.config.activeSigningMode() == "nip46" {
            NIP46Service.shared.connectFromConfig()
        }

        // Reconnect the notes WebSocket after the app was suspended.
        // The relay is still in-process; it un-freezes the moment we foreground.
        // Give it a second to settle then re-fetch notes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard RelayProcessManager.shared.isRunning else { return }
            NostrService.shared.resetConnections()
            // Mark that we handled foreground reconnection so ViewerView
            // doesn't redundantly call refreshAll() on its next onAppear.
            NostrService.shared.lastForegroundReconnectTime = Date()
            let config = ConfigService.shared.config
            var urls = [config.nostrURL, config.nostrURL + "/inbox"].compactMap { URL(string: $0) }
            guard !urls.isEmpty else { return }
            let macURL = config.macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !macURL.isEmpty, let macInbox = URL(string: macURL + "/inbox") {
                urls.append(macInbox)
            }
            NostrService.shared.fetchNotes(from: urls)

            // Rescan blossom directory for media that arrived while backgrounded
            NotificationCenter.default.post(name: .blossomDirectoryChanged, object: nil)

            // Refresh DM inbox to pick up messages received while backgrounded
            DMService.shared.refresh()

            // Reconnect feed WebSocket connections killed during suspend
            if !FeedService.shared.isPaused {
                FeedService.shared.pauseFeed()
            }
            FeedService.shared.resumeFeed()
        }
        
        // Sync DMs from external relays on foreground
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            DMService.shared.syncOnForeground()
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Disconnect NIP-46 remote signer to free resources while backgrounded
        if ConfigService.shared.config.activeSigningMode() == "nip46" {
            NIP46Service.shared.disconnect()
        }

        // Pause feed & reset viewer connections when entering background
        FeedService.shared.pauseFeed()
        NostrService.shared.resetConnections()

        // Request background execution time from iOS.
        // This gives ~30 seconds for the relay goroutines to finish in-flight work
        // (e.g. writing an event to BadgerDB) before the process is suspended.
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "relay-wind-down") { [weak self] in
            // Expiry handler: iOS is about to suspend us. Wrap up.
            self?.endBackgroundTask()
        }

        // Also schedule a BGProcessingTask so iOS can wake us later
        // (e.g. when plugged in and on Wi-Fi) for a longer relay window.
        AppDelegate.scheduleBackgroundProcessing()
    }

    // MARK: - Helpers

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}