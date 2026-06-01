import UIKit
import BackgroundTasks
import UserNotifications

/// Background task identifiers — must also be declared in Info.plist under
/// BGTaskSchedulerPermittedIdentifiers.
private let kBGProcessingTaskID = "com.haven.relay.processing"

private let kBGRefreshTaskID = "com.haven.relay.refresh"

/// Queued notification action to replay once the UI is ready.
struct PendingNotificationAction {
    let eventId: String?
    let eventKind: Int
    let recipientPubkey: String?
}

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    /// When `true`, the app allows landscape orientation (used by media viewers).
    static var allowLandscape = false

    /// Stores a pending notification action when the relay isn't ready yet.
    /// ContentView replays this once the relay is running and views are mounted.
    static var pendingAction: PendingNotificationAction?

    /// Dispatches a notification action immediately (posts NSNotification + triggers refresh).
    static func dispatchAction(_ action: PendingNotificationAction) {
        pendingAction = nil
        Task { @MainActor in
            // Switch to the correct account if the notification is for a different one
            if let recipientHex = action.recipientPubkey,
               !recipientHex.isEmpty,
               let hexData = Data(hexString: recipientHex),
               let npub = Bech32.encode(hrp: "npub", data: hexData) {
                ConfigService.shared.switchActiveAccount(to: npub)
            }

            switch action.eventKind {
            case 1059, 4:
                DMService.shared.refresh()
                NotificationCenter.default.post(name: .havenOpenDMInbox, object: nil)
            case 1:
                NotificationCenter.default.post(name: .havenOpenMentions, object: action.eventId)
            case 7:
                NotificationCenter.default.post(name: .havenOpenRelayLikes, object: nil)
            case 6:
                NotificationCenter.default.post(name: .havenOpenRelayNotes, object: nil)
            case 9735:
                NotificationCenter.default.post(name: .havenOpenRelayZaps, object: nil)
            default:
                break
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Register the background processing task so the system can wake us
        // when conditions are right (charging + Wi-Fi).
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: kBGProcessingTaskID,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handleBackgroundProcessingTask(processingTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: kBGRefreshTaskID,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handleAppRefreshTask(refreshTask)
        }

        // Set notification center delegate
        UNUserNotificationCenter.current().delegate = self

        // Only register for push notifications if the user has already
        // completed setup (has an npub). First-time users will be prompted
        // after the setup wizard finishes.
        if ConfigService.shared.config.hasCompletedSetup {
            Task { @MainActor in
                PushNotificationService.shared.requestPermissionAndRegister()
            }
            Self.scheduleAppRefresh()
        }

        return true
    }

    // MARK: - Remote Notifications (APNs)

    /// Called when APNs registration succeeds
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            PushNotificationService.shared.didRegister(deviceTokenData: deviceToken)
        }
    }

    /// Called when APNs registration fails
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            PushNotificationService.shared.didFailToRegister(error: error)
        }
    }

    // MARK: - Orientation Lock

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        if Self.allowLandscape {
            return [.portrait, .landscapeLeft, .landscapeRight]
        }
        return .portrait
    }

    // MARK: - Background App Refresh (no push server needed!)

    static func handleAppRefreshTask(_ task: BGAppRefreshTask) {
        scheduleAppRefresh()
        
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        
        Task { @MainActor in
            let countBefore = FeedService.shared.notes.count
            FeedService.shared.refresh()

            // Also sync from Mac relay if configured
            MacRelaySyncService.shared.syncIfConfigured()

            // Give it up to 25s to connect to relays and receive events
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            let newCount = FeedService.shared.notes.count - countBefore
            if newCount > 0 {
                PushNotificationService.showFeedNotification(newCount: newCount)
            }
            task.setTaskCompleted(success: true)
        }
    }
    
    static func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: kBGRefreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes
        try? BGTaskScheduler.shared.submit(request)
    }


    // MARK: UISceneSession Lifecycle

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(
        _ application: UIApplication,
        didDiscardSceneSessions sceneSessions: Set<UISceneSession>
    ) {}

    // MARK: - Background Processing Task

    /// Called by BGTaskScheduler when the system grants background processing time.
    private static func handleBackgroundProcessingTask(_ task: BGProcessingTask) {
        scheduleBackgroundProcessing()
        task.expirationHandler = {
            task.setTaskCompleted(success: true)
        }
        task.setTaskCompleted(success: true)
    }

    /// Schedule the next BGProcessingTask request.
    static func scheduleBackgroundProcessing() {
        let request = BGProcessingTaskRequest(identifier: kBGProcessingTaskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Handle notification when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner, play sound, and update badge even when app is open
        completionHandler([.banner, .sound, .badge])
    }

    /// Handle notification tap
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            PushNotificationService.shared.clearBadge()
        }

        let userInfo = response.notification.request.content.userInfo

        if let eventId = userInfo["event_id"] as? String,
           let eventKind = userInfo["event_kind"] as? Int {
            let recipientPubkey = userInfo["recipient_pubkey"] as? String
            let action = PendingNotificationAction(eventId: eventId, eventKind: eventKind, recipientPubkey: recipientPubkey)

            // If the relay is already running, dispatch immediately.
            // Otherwise queue for ContentView to replay when ready.
            if RelayProcessManager.shared.isRunning {
                Self.dispatchAction(action)
            } else {
                Self.pendingAction = action
            }
        }

        completionHandler()
    }
}
