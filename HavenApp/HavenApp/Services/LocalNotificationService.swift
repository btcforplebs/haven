import Foundation
import SwiftUI
import UserNotifications

/// Fires local system notifications from the embedded relay's `🔔NOTIFY|` log markers.
/// Mirrors Android's LocalNotificationService.kt — no push server required.
///
/// Feed via RelayProcessManager.applyBatchedUpdate() whenever it sees a
/// `🔔NOTIFY|` line in the relay's stdout pipe.
@MainActor
final class LocalNotificationService {
    static let shared = LocalNotificationService()
    private init() {}

    /// True while the app is foregrounded. The system notification is suppressed while
    /// active (it can't banner over a running app) and replaced with an in-app banner
    /// (RelayActivityBanner) instead, so live activity is never silently dropped.
    var appInForeground: Bool = false

    private var seen = Set<String>()
    private let maxSeen = 500
    private let seenLock = NSLock()

    // MARK: - Entry point

    /// Called on the main actor from RelayProcessManager.applyBatchedUpdate()
    /// with the text after the `🔔NOTIFY|` prefix.
    func handle(_ markerBody: String) {
        guard ConfigService.shared.config.enablePushNotifications else { return }

        // preview is always last and may contain spaces/pipes — split it off first
        let previewKey = "|preview="
        let head: String
        let preview: String
        if let r = markerBody.range(of: previewKey) {
            head = String(markerBody[markerBody.startIndex..<r.lowerBound])
            preview = String(markerBody[r.upperBound...])
        } else {
            head = markerBody
            preview = ""
        }

        var fields: [String: String] = [:]
        for part in head.split(separator: "|") {
            let s = String(part)
            if let eq = s.firstIndex(of: "=") {
                fields[String(s[..<eq])] = String(s[s.index(after: eq)...])
            }        }

         guard let type = fields["type"], let id = fields["id"], !id.isEmpty else { return }
        let author = fields["author"] ?? ""

        guard markSeen(id) else { return }

        let npub = ConfigService.shared.config.activeAccountNpub.isEmpty
            ? ConfigService.shared.config.ownerNpub
            : ConfigService.shared.config.activeAccountNpub
        let prefs = PushNotificationService.shared.preferencesForAccount(npub)

        let allowed: Bool = {
            switch type {
            case "mention":        return prefs.mentions
            case "reply":          return prefs.replies
            case "dm", "giftwrap": return prefs.dms
            case "zap":            return prefs.zaps
            case "reaction":       return prefs.reactions
            case "repost":         return prefs.reposts
            default:               return false
            }
        }()
        guard allowed else { return }

        let name = author.isEmpty ? nil : NostrService.shared.profiles[author]?.bestName

        if appInForeground {
            showInAppBanner(id: id, type: type, name: name, preview: preview)
        } else {
            post(id: id, type: type, name: name, preview: preview)
        }
    }

    // MARK: - Private

    private func markSeen(_ id: String) -> Bool {
        seenLock.lock()
        defer { seenLock.unlock() }
        guard seen.insert(id).inserted else { return false }
        if seen.count > maxSeen {
            seen = Set(seen.dropFirst(maxSeen / 2))
        }
        return true
    }

    private func titleAndBody(type: String, name: String?, preview: String) -> (String, String) {
        let who = name ?? "Someone"
        switch type {
        case "mention":
            return ("\(who) mentioned you",
                    preview.isEmpty ? "You were mentioned in a note" : preview)
        case "reply":
            return ("\(who) replied to your note",
                    preview.isEmpty ? "Tap to view the reply" : preview)
        case "dm", "giftwrap":
            return (name != nil ? "Message from \(who)" : "New message",
                    "You have a new encrypted message")
        case "zap":
            return ("⚡ New zap",
                    name != nil ? "\(who) zapped you" : "You received a zap")
        case "reaction":
            return ("\(who) reacted \(preview.isEmpty ? "❤️" : preview)",
                    "Tap to view your note")
        case "repost":
            return ("\(who) reposted your note", "Tap to view")
        default:
            return ("New activity", "Tap to view")
        }
    }

    /// Shows the in-app drop-down banner (RelayActivityBanner) for activity that arrives
    /// while the app is foregrounded, tappable to jump straight to the relevant tab/note.
    private func showInAppBanner(id: String, type: String, name: String?, preview: String) {
        let (title, body) = titleAndBody(type: type, name: name, preview: preview)
        let (icon, color) = iconAndColor(for: type)
        RelayActivityNotificationManager.shared.show(icon: icon, title: title, body: body, color: color) {
            Self.navigate(type: type, id: id)
        }
    }

    private func iconAndColor(for type: String) -> (String, Color) {
        switch type {
        case "mention":        return ("at", Color.havenPurple)
        case "reply":          return ("arrowshape.turn.up.left.fill", Color.havenPurple)
        case "dm", "giftwrap": return ("envelope.fill", Color.blue)
        case "zap":            return ("bolt.fill", Color.orange)
        case "reaction":       return ("heart.fill", Color.pink)
        case "repost":         return ("arrow.2.squarepath", Color(red: 0.2, green: 0.8, blue: 0.6))
        default:               return ("bell.fill", Color.gray)
        }
    }

    /// Mirrors AppDelegate's notification-tap dispatch so the in-app banner opens the
    /// same destination a system notification of the same type would.
    private static func navigate(type: String, id: String) {
        switch type {
        case "mention", "reply":
            NotificationCenter.default.post(name: .havenOpenMentions, object: id)
        case "reaction":
            NotificationCenter.default.post(name: .havenOpenRelayLikes, object: nil)
        case "repost":
            NotificationCenter.default.post(name: .havenOpenRelayNotes, object: nil)
        case "zap":
            NotificationCenter.default.post(name: .havenOpenRelayZaps, object: nil)
        case "dm", "giftwrap":
            NotificationCenter.default.post(name: .havenOpenDMInbox, object: nil)
        default:
            break
        }
    }

    private func post(id: String, type: String, name: String?, preview: String) {
        let (title, body) = titleAndBody(type: type, name: name, preview: preview)

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound(named: UNNotificationSoundName("notification.mp3"))
        content.categoryIdentifier = "RELAY_EVENT"
        content.userInfo = ["notif_type": type]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "haven-relay-\(id)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }
}
