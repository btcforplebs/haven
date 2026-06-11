#if os(macOS)
import AppKit

/// Observes system sleep/wake. The embedded relay runs in-process and
/// survives sleep, but its sockets die — for a window after wake, network
/// operations fail while connections re-establish. Automatic recovery
/// paths (Blossom's relay restart) must not interpret those failures as
/// a wedged relay: a restart cycle right after wake is exactly the
/// background stop/start churn that used to corrupt BadgerDB.
@MainActor
final class SleepWakeMonitor {
    static let shared = SleepWakeMonitor()

    /// How long after wake automatic relay restarts stay suppressed.
    static let wakeGraceInterval: TimeInterval = 45

    private(set) var wakeGraceUntil: Date = .distantPast
    private var started = false

    var isInWakeGracePeriod: Bool { Date() < wakeGraceUntil }

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                // Open the grace window now in case didWake arrives late —
                // operations resumed mid-transition must not trigger restarts.
                SleepWakeMonitor.shared.wakeGraceUntil = .distantFuture
                RelayProcessManager.shared.addLog("System will sleep — relay stays up; automatic recovery suppressed")
            }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                SleepWakeMonitor.shared.wakeGraceUntil = Date().addingTimeInterval(Self.wakeGraceInterval)
                RelayProcessManager.shared.addLog("System woke — suppressing automatic relay restarts for \(Int(Self.wakeGraceInterval))s while connections re-establish")
                NotificationCenter.default.post(name: .havenSystemDidWake, object: nil)
            }
        }
    }
}

extension Notification.Name {
    /// Posted on the main queue after the system wakes from sleep, once the
    /// post-wake grace window has been opened.
    static let havenSystemDidWake = Notification.Name("com.haven.systemDidWake")
}
#endif
