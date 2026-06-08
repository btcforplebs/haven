import Foundation

// MARK: - Group Identity

/// Uniquely identifies a NIP-29 group across the Nostr network.
/// Groups are identified by `<relay-host>'<group-id>`.
struct GroupIdentifier: Codable, Hashable, Equatable {
    let relayURL: String
    let groupId: String

    /// Canonical NIP-29 identifier: `<relay-host>'<group-id>`
    var canonicalId: String {
        let host = relayURL
            .replacingOccurrences(of: "wss://", with: "")
            .replacingOccurrences(of: "ws://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(host)'\(groupId)"
    }
}

// MARK: - Group Metadata (from Kind 39000)

struct GroupInfo: Codable, Identifiable, Equatable {
    let identifier: GroupIdentifier
    var name: String
    var picture: String
    var about: String
    var isPrivate: Bool
    var isClosed: Bool
    var memberCount: Int?

    var id: String { identifier.canonicalId }
    var pictureURL: URL? { URL(string: picture) }
}

// MARK: - Group Member (from Kind 39001/39002)

struct GroupMember: Codable, Identifiable, Equatable {
    let pubkey: String
    var roles: [String]

    var id: String { pubkey }
    var isAdmin: Bool { roles.contains("admin") }
    var isModerator: Bool { roles.contains("moderator") || roles.contains("admin") }
}

// MARK: - Group Message

struct GroupMessage: Codable, Identifiable, Equatable {
    let id: String
    let groupId: String
    let senderPubkey: String
    let content: String
    let timestamp: Date
    let kind: Int
    let tags: [[String]]
    let isFromMe: Bool

    var parentEventId: String? {
        tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1]
    }

    var mediaURLs: [URL] {
        let ns = content as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let regex = try? NSRegularExpression(
            pattern: #"https?://\S+\.(?:jpg|jpeg|png|gif|webp|mp4|mov|webm|mp3|m4a|ogg)"#,
            options: .caseInsensitive
        ) else { return [] }
        return regex.matches(in: content, range: range)
            .compactMap { URL(string: ns.substring(with: $0.range)) }
    }
}

// MARK: - Group Conversation

struct GroupConversation: Codable, Identifiable {
    let identifier: GroupIdentifier
    var info: GroupInfo?
    var messages: [GroupMessage]
    var unreadCount: Int
    var members: [GroupMember]
    var admins: [GroupMember]

    var id: String { identifier.canonicalId }
    var lastMessage: GroupMessage? { messages.last }

    var displayName: String {
        info?.name ?? identifier.groupId
    }
}

// MARK: - Joined Group (for HavenConfig persistence)

struct JoinedGroup: Codable, Equatable {
    let relayURL: String
    let groupId: String
    var displayName: String
}
