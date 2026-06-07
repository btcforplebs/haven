import Foundation
import Combine

@MainActor
class FollowingBackupService: ObservableObject {
    static let shared = FollowingBackupService()

    @Published var snapshots: [FollowingSnapshot] = []

    private var loadedAccountKey: String = ""

    // MARK: - Persistence

    func loadSnapshots(forAccountKey key: String) {
        loadedAccountKey = key
        let url = Self.fileURL(forAccountKey: key)
        guard FileManager.default.fileExists(atPath: url.path) else {
            snapshots = []
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let store = try JSONDecoder().decode(FollowingSnapshotStore.self, from: data)
            snapshots = store.snapshots
        } catch {
            RelayProcessManager.shared.addLog("Failed to load following snapshots: \(error.localizedDescription)", level: "ERROR")
            snapshots = []
        }
    }

    private func saveSnapshots(forAccountKey key: String) {
        let store = FollowingSnapshotStore(snapshots: snapshots)
        let url = Self.fileURL(forAccountKey: key)
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(store) {
                try? data.write(to: url)
            }
        }
    }

    private static func fileURL(forAccountKey key: String) -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Haven")
        }
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        try? FileManager.default.createDirectory(at: havenDir, withIntermediateDirectories: true)
        let safeKey = key.isEmpty ? "owner" : key.replacingOccurrences(of: "/", with: "_")
        return havenDir.appendingPathComponent("following_snapshots_\(safeKey).json")
    }

    // MARK: - Snapshot Management

    /// Called after contact list loads from relays. Creates a new snapshot only if the
    /// pubkey set differs from the most recent snapshot. Skips empty lists.
    func maybeCreateSnapshot(
        pubkeys: [String],
        pTags: [[String]],
        contactListContent: String,
        forAccountKey key: String
    ) {
        // Never snapshot an empty contact list
        guard !pubkeys.isEmpty else { return }

        // Ensure we're loaded for the right account
        if loadedAccountKey != key {
            loadSnapshots(forAccountKey: key)
        }

        // Check if the pubkey set differs from the most recent snapshot
        if let latest = snapshots.last {
            let currentSet = Set(pubkeys)
            let latestSet = Set(latest.pubkeys)
            if currentSet == latestSet { return }
        }

        let snapshot = FollowingSnapshot(
            id: UUID(),
            capturedAt: Date(),
            pubkeys: pubkeys,
            pTags: pTags,
            contactListContent: contactListContent
        )
        snapshots.append(snapshot)

        // Prune oldest beyond the limit
        if snapshots.count > FollowingSnapshotStore.maxSnapshots {
            let excess = snapshots.count - FollowingSnapshotStore.maxSnapshots
            snapshots.removeFirst(excess)
        }

        saveSnapshots(forAccountKey: key)
    }

    func deleteSnapshot(id: UUID, forAccountKey key: String) {
        snapshots.removeAll { $0.id == id }
        saveSnapshots(forAccountKey: key)
    }

    // MARK: - Comparison

    /// Returns pubkeys present in the snapshot but NOT in the current following list.
    func removedSince(snapshot: FollowingSnapshot, currentPubkeys: [String]) -> [String] {
        let currentSet = Set(currentPubkeys)
        return snapshot.pubkeys.filter { !currentSet.contains($0) }
    }

    /// Returns pubkeys present in the current following list but NOT in the snapshot.
    func addedSince(snapshot: FollowingSnapshot, currentPubkeys: [String]) -> [String] {
        let snapshotSet = Set(snapshot.pubkeys)
        return currentPubkeys.filter { !snapshotSet.contains($0) }
    }
}
