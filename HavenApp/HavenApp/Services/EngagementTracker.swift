import Foundation

/// Pure engagement bookkeeping — likes, zaps, reposts, and per-note stats.
/// No Combine, no @Published. FeedService delegates state mutations here
/// and assigns results to its published properties.
enum EngagementTracker {

    // MARK: - Interaction State (Persistence Model)

    /// Codable snapshot of the user's engagement state (which notes they've
    /// liked/zapped), persisted to disk per account.
    struct InteractionState: Codable {
        let likedEventIds: Set<String>
        let zappedEventIds: [String: Int]

        init(likedEventIds: Set<String>, zappedEventIds: [String: Int]) {
            self.likedEventIds = likedEventIds
            self.zappedEventIds = zappedEventIds
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            likedEventIds = try container.decode(Set<String>.self, forKey: .likedEventIds)
            // Migrate from old Set<String> format if needed
            if let dict = try? container.decode([String: Int].self, forKey: .zappedEventIds) {
                zappedEventIds = dict
            } else if let set = try? container.decode(Set<String>.self, forKey: .zappedEventIds) {
                zappedEventIds = Dictionary(uniqueKeysWithValues: set.map { ($0, 0) })
            } else {
                zappedEventIds = [:]
            }
        }
    }

    // MARK: - File Paths

    /// Returns the per-account interaction state file URL.
    static func interactionStateURL(forKey key: String) -> URL {
        let havenDir = havenSupportDir()
        let safeKey = key.isEmpty ? "owner" : key.replacingOccurrences(of: "/", with: "_")
        return havenDir.appendingPathComponent("interaction_state_\(safeKey).json")
    }

    /// Returns the legacy (pre-per-account) interaction state file URL.
    static func legacyInteractionStateURL() -> URL {
        return havenSupportDir().appendingPathComponent("interaction_state.json")
    }

    private static func havenSupportDir() -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Haven")
        }
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        try? FileManager.default.createDirectory(at: havenDir, withIntermediateDirectories: true)
        return havenDir
    }

    // MARK: - Load / Save

    /// Loads interaction state from disk for the given account key.
    /// Falls back to the legacy global file when no per-account file exists.
    static func loadInteractionState(forKey key: String) -> (likedEventIds: Set<String>, zappedEventIds: [String: Int]) {
        let url = interactionStateURL(forKey: key)
        if let data = try? Data(contentsOf: url),
           let state = try? JSONDecoder().decode(InteractionState.self, from: data) {
            return (state.likedEventIds, state.zappedEventIds)
        }

        // Migration: read the old shared file
        let legacy = legacyInteractionStateURL()
        if let data = try? Data(contentsOf: legacy),
           let state = try? JSONDecoder().decode(InteractionState.self, from: data) {
            return (state.likedEventIds, state.zappedEventIds)
        }

        return ([], [:])
    }

    /// Persists interaction state to disk. Runs the encode + write on a
    /// background queue to avoid blocking the main thread.
    static func saveInteractionState(
        likedEventIds: Set<String>,
        zappedEventIds: [String: Int],
        forKey key: String
    ) {
        let state = InteractionState(likedEventIds: likedEventIds, zappedEventIds: zappedEventIds)
        let url = interactionStateURL(forKey: key)
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(state) {
                try? data.write(to: url)
            }
        }
    }

    // MARK: - Self-Like Detection

    /// Identifies reactions authored by the owner in a batch of reaction events.
    /// Returns the note IDs that the owner has liked.
    static func detectSelfLikes(
        reactions: [(targetId: String, pubkey: String)],
        ownerHex: String
    ) -> [String] {
        guard !ownerHex.isEmpty else { return [] }
        return reactions.compactMap { $0.pubkey == ownerHex ? $0.targetId : nil }
    }

    // MARK: - Engagement Count Merging

    /// Merges a batch of reaction events and repost targets into the running
    /// per-note stats dictionary. Returns the updated dictionary.
    static func mergeEngagementCounts(
        reactions: [(targetId: String, pubkey: String)],
        repostTargets: [String],
        currentStats: [String: NoteStats]
    ) -> [String: NoteStats] {
        var updated = currentStats
        for (targetId, _) in reactions {
            var s = updated[targetId] ?? NoteStats()
            s.reactions += 1
            updated[targetId] = s
        }
        for targetId in repostTargets {
            var s = updated[targetId] ?? NoteStats()
            s.reposts += 1
            updated[targetId] = s
        }
        return updated
    }
}
