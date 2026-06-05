import SwiftUI
#if os(iOS)
import UIKit

@MainActor
class iOSAppDelegate: NSObject, UIApplicationDelegate, ObservableObject {
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Ignore SIGPIPE so broken pipe writes don't kill the process
        signal(SIGPIPE, SIG_IGN)

        // Auto-start relay on launch
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard ConfigService.shared.config.autoStartRelay else { return }
            guard ConfigService.shared.config.hasCompletedSetup else { return }
            guard RelayProcessManager.shared.state == .idle else { return }

            #if DEBUG
            print("iOS: Auto-starting relay on launch...")
            #endif

            RelayProcessManager.shared.startRelay(config: ConfigService.shared.config)

            if ConfigService.shared.config.activeSigningMode() == "nip46" {
                NIP46Service.shared.connectFromConfig()
            }

            // Publish NIP-65 relay lists for accounts with the setting enabled
            try? await Task.sleep(for: .seconds(5))
            NostrService.shared.publishRelayListsForEnabledAccounts()

            // Start profile picture prefetch service (runs once per day on Wi-Fi)
            try? await Task.sleep(for: .seconds(5))
            ProfilePicturePrefetchService.shared.start()
        }

        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        #if DEBUG
        print("iOS: App entering background - requesting background time to keep relay alive")
        #endif

        // Request background time to keep relay running
        backgroundTask = application.beginBackgroundTask { [weak self] in
            #if DEBUG
            print("iOS: Background time expiring - cleaning up")
            #endif
            self?.endBackgroundTask()
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        #if DEBUG
        print("iOS: App entering foreground - ending background task")
        #endif

        // End background task when returning to foreground
        endBackgroundTask()

        // Check if relay is still running, restart if needed
        Task { @MainActor in
            if ConfigService.shared.config.autoStartRelay &&
               ConfigService.shared.config.hasCompletedSetup &&
               RelayProcessManager.shared.state == .idle {
                #if DEBUG
                print("iOS: Relay stopped while backgrounded, restarting...")
                #endif
                RelayProcessManager.shared.startRelay(config: ConfigService.shared.config)
            }
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        #if DEBUG
        print("iOS: Application terminating, stopping relay...")
        #endif

        RelayProcessManager.shared.stopRelay()
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }

        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
#endif
