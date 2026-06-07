#if os(macOS)
import Foundation
import Combine

/// Detects whether nostr-vpn (nvpn) is running by reading its file-based IPC.
/// No subprocess or CLI dependency required — reads config.toml and daemon.state.json directly.
final class FIPSDetectionService: ObservableObject {
    enum Status: Equatable {
        case notInstalled
        case installed
        case running
        case stale
    }

    @Published var status: Status = .notInstalled
    @Published var detectedNpub: String? = nil

    private var timer: Timer?

    private static let daemonStateFreshnessSeconds: UInt64 = 10

    /// Resolved config directory. Checks the Mac app location first, then CLI fallback.
    private lazy var configDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Mac app: ~/Library/Application Support/nvpn/
        let appSupport = home.appendingPathComponent("Library/Application Support/nvpn")
        if FileManager.default.fileExists(atPath: appSupport.appendingPathComponent("config.toml").path) {
            return appSupport
        }
        // CLI fallback: ~/.config/nvpn/
        return home.appendingPathComponent(".config/nvpn")
    }()

    private var configFile: URL {
        configDir.appendingPathComponent("config.toml")
    }

    private var stateFile: URL {
        configDir.appendingPathComponent("daemon.state.json")
    }

    func startPolling(interval: TimeInterval = 5.0) {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func check() {
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            update(.notInstalled, npub: nil)
            return
        }

        // Read npub from config.toml
        var npub: String? = nil
        if let contents = try? String(contentsOf: configFile, encoding: .utf8) {
            npub = parseNpubFromConfig(contents)
        }

        // Check daemon state
        guard let stateData = try? Data(contentsOf: stateFile),
              let state = try? JSONSerialization.jsonObject(with: stateData) as? [String: Any] else {
            update(.installed, npub: npub)
            return
        }

        let vpnActive = state["vpn_active"] as? Bool ?? false
        let updatedAt = state["updated_at"] as? UInt64 ?? 0
        let now = UInt64(Date().timeIntervalSince1970)
        let fresh = updatedAt > 0 && (now - updatedAt) <= Self.daemonStateFreshnessSeconds

        if vpnActive && fresh {
            update(.running, npub: npub)
        } else if updatedAt > 0 {
            update(.stale, npub: npub)
        } else {
            update(.installed, npub: npub)
        }
    }

    private func update(_ newStatus: Status, npub: String?) {
        if Thread.isMainThread {
            status = newStatus
            detectedNpub = npub
        } else {
            DispatchQueue.main.async {
                self.status = newStatus
                self.detectedNpub = npub
            }
        }
    }

    /// Parse public_key from nvpn's TOML config (line-based, no TOML dependency).
    private func parseNpubFromConfig(_ contents: String) -> String? {
        var inNostrSection = false
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[nostr]" {
                inNostrSection = true
                continue
            }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inNostrSection = false
                continue
            }
            if inNostrSection && trimmed.hasPrefix("public_key") {
                if let start = trimmed.firstIndex(of: "\""),
                   let end = trimmed[trimmed.index(after: start)...].firstIndex(of: "\"") {
                    let value = String(trimmed[trimmed.index(after: start)..<end])
                    if value.hasPrefix("npub1") {
                        return value
                    }
                }
            }
        }
        return nil
    }
}
#endif
