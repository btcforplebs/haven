import Foundation

// MARK: - Relay-Fetched Kind 3 Events (Recovery)

/// Represents a Kind 3 contact list event fetched from a relay.
/// Used by the recovery UI to display historical contact lists.
struct Kind3Event: Identifiable {
    let id: String          // Nostr event ID
    let createdAt: Date     // From created_at timestamp
    let pubkeys: [String]   // Hex pubkeys extracted from p-tags
    let pTags: [[String]]   // Full NIP-02 p-tags (preserves relay hints, petnames)
    let content: String     // Kind 3 content field (relay config JSON)
    var followCount: Int { pubkeys.count }
}

// MARK: - Local Snapshots (Automatic Backup)

/// A point-in-time capture of the user's contact list, saved locally.
struct FollowingSnapshot: Codable, Identifiable {
    let id: UUID
    let capturedAt: Date
    let pubkeys: [String]
    let pTags: [[String]]
    let contactListContent: String
    var followCount: Int { pubkeys.count }
}

/// Container for all snapshots belonging to one account.
struct FollowingSnapshotStore: Codable {
    var snapshots: [FollowingSnapshot]
    static let maxSnapshots = 50
}
