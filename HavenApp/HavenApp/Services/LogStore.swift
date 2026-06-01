import Foundation
import Combine

/// Dedicated observable for relay logs, decoupled from RelayProcessManager
/// so that log updates only trigger redraws in LogsView — not every view
/// that observes RelayProcessManager.
///
/// All mutations are funnelled through the throttled `flush()` method to
/// avoid reentrant NSTableView delegate updates (SwiftUI List on macOS
/// uses NSTableView internally — mutating the data source mid-layout causes
/// "reentrant operation in its NSTableView delegate" warnings that will
/// become crashes in a future macOS release).
@MainActor
class LogStore: ObservableObject {
    @Published var logs: [RelayProcessManager.LogEntry] = []

    private var pendingLogs: [RelayProcessManager.LogEntry] = []
    private var logUpdateTimer: Timer?

    func startThrottler() {
        stopThrottler()
        logUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.flush()
            }
        }
    }

    func stopThrottler() {
        logUpdateTimer?.invalidate()
        logUpdateTimer = nil
        flush()
    }

    /// Queue entries from a background thread (via Task { @MainActor })
    func enqueue(_ entries: [RelayProcessManager.LogEntry]) {
        pendingLogs.append(contentsOf: entries)
    }

    /// Queue a single entry for the next throttled flush instead of
    /// mutating `logs` directly, preventing reentrant NSTableView updates.
    func append(_ entry: RelayProcessManager.LogEntry) {
        pendingLogs.append(entry)
        // If the throttler isn't running, schedule a one-shot flush so
        // the entry still appears promptly.
        if logUpdateTimer == nil {
            DispatchQueue.main.async { [weak self] in
                self?.flush()
            }
        }
    }

    private func flush() {
        guard !pendingLogs.isEmpty else { return }
        let batch = pendingLogs
        pendingLogs.removeAll()

        logs.append(contentsOf: batch)
        if logs.count > 1000 {
            logs.removeFirst(max(0, logs.count - 1000))
        }
    }
}
