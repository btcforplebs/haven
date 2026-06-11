import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor
class AppDelegate: NSObject, ObservableObject {
    #if os(macOS)
    // Keep a reference to the window prevent it from being deallocated immediately
    private var welcomeWindow: NSWindow?
    #endif

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ignore SIGPIPE so broken pipe writes (e.g. from the Go relay's
        // stdout redirection) don't silently kill the process.
        signal(SIGPIPE, SIG_IGN)

        #if os(macOS)
        // Watch sleep/wake so automatic recovery doesn't restart the relay
        // over connections that are merely re-establishing after wake.
        SleepWakeMonitor.shared.start()

        // Check if setup is complete
        if !ConfigService.shared.config.hasCompletedSetup {
            openWelcomeWindow()
        } else {
            // Auto-start relay after the app is fully initialised.
            // Uses a Task with a brief sleep so the SwiftUI scene and
            // Go runtime are ready before we call into StartRelayC.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard ConfigService.shared.config.autoStartRelay else { return }
                guard RelayProcessManager.shared.state == .idle else { return }
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
        }
        #endif
    }

    #if os(macOS)
    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        #if DEBUG
        print("Application terminating, stopping relay...")
        #endif

        // Persist the current feed so the next cold launch restores it instantly.
        // The encode + write runs off-main; the relay-stop semaphore wait below
        // gives it time to flush before the process exits.
        FeedService.shared.persistCurrentSnapshot()

        // Stop background services before relay shutdown
        NetworkSyncService.shared.stop()
        NIP46Service.shared.disconnect()

        // Stop the relay directly, bypassing the serialized lifecycle chain —
        // termination must not wait behind a queued backup or restart. The Go
        // side's lifecycle mutex makes a direct StopRelayC safe even against
        // an in-flight operation, and stopping an already-stopped relay is a
        // no-op. We block briefly so the process doesn't exit before the Go
        // side has flushed and closed the databases.
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            StopRelayC()
            semaphore.signal()
        }
        // Wait up to 5 seconds for a clean shutdown; if it takes longer the
        // OS will SIGKILL us anyway.
        _ = semaphore.wait(timeout: .now() + 5.0)
    }
    
    func openWelcomeWindow() {
        // Create the window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
            styleMask: [.titled, .closable, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .windowBackgroundColor
        
        // Prepare the content view with shared environment objects
        let contentView = SetupWizardView { [weak window] in
            // On complete:
            #if DEBUG
            print("Setup complete, starting relay from AppDelegate...")
            #endif
            Task { @MainActor in
                RelayProcessManager.shared.startRelay(config: ConfigService.shared.config)
            }
            window?.close()
        }
        .environmentObject(ConfigService.shared)
        .environmentObject(RelayProcessManager.shared)
        .environmentObject(NostrService.shared)
        .environmentObject(StatsService.shared)
        .frame(minWidth: 500, minHeight: 650)
        
        window.contentView = NSHostingView(rootView: contentView)
        
        // Show the window
        window.makeKeyAndOrderFront(nil)
        window.level = .normal // Standard window level
        NSApp.activate(ignoringOtherApps: true)
        
        self.welcomeWindow = window
    }
    #endif
}

#if os(macOS)
extension AppDelegate: NSApplicationDelegate {}
#endif
