import Foundation

/// Selectable notification sounds, bundled flat in Resources (required for
/// `UNNotificationSoundName`, which only ever looks up a bare filename — see
/// LocalNotificationService.playSound() and PushNotificationService).
enum NotificationSound: String, CaseIterable, Identifiable {
    case chime = "Chime"
    case confident = "Confident"
    case juntos = "Juntos"
    case ping = "Ping"

    static let defaultSound: NotificationSound = .chime

    var id: String { rawValue }

    var displayName: String { rawValue }

    var fileName: String { "\(rawValue).mp3" }

    /// Value UNNotificationSound(named:) expects — the bare resource filename.
    var systemSoundName: String { fileName }
}
