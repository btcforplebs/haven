import Foundation

/// Pure filtering and sorting functions for the feed pipeline.
/// All inputs are explicit parameters — no @Published, no Combine, no singletons.
/// Direct translation target for Kotlin (pure functions -> pure functions).
enum FeedFilterEngine {

    // MARK: - Feed Note Filtering

    /// Filters and sorts notes for the main feed based on mode and user preferences.
    ///
    /// - Parameters:
    ///   - notes: All notes currently in memory.
    ///   - mode: The active feed mode (following, discovery, global, popular, media).
    ///   - blocked: Hex pubkeys the user has blocked.
    ///   - showReposts: Whether kind-6 reposts should be visible.
    ///   - showReplies: Whether replies should be visible.
    ///   - followedPubkeys: Hex pubkeys the user follows.
    ///   - wotPubkeys: Web-of-Trust pubkey set (for global feed filtering).
    ///   - popularFilter: Sub-filter for the Popular feed (all / follows / non-follows).
    ///   - popularNoteScores: Popularity scores keyed by note ID (from the DVM).
    ///   - throttledPubkeys: Authors whose posts are rate-limited (pubkey -> max visible posts).
    /// - Returns: Filtered and sorted array of notes ready for display.
    static func filterFeedNotes(
        notes: [FeedNote],
        mode: FeedMode,
        blocked: Set<String>,
        showReposts: Bool,
        showReplies: Bool,
        followedPubkeys: [String],
        wotPubkeys: Set<String>,
        popularFilter: PopularFilter,
        popularNoteScores: [String: Double],
        throttledPubkeys: [String: Int]
    ) -> [FeedNote] {
        var filtered = notes.filter { note in
            if blocked.contains(note.pubkey) { return false }
            if note.kind == 6 && !showReposts { return false }
            if mode == .popular {
                let isFollowed = followedPubkeys.contains(note.pubkey)
                if popularFilter == .follows && !isFollowed { return false }
                if popularFilter == .nonFollows && isFollowed { return false }
                return !note.isReply
            }
            if mode == .global {
                if !wotPubkeys.isEmpty && !wotPubkeys.contains(note.pubkey) { return false }
                return !note.isReply
            }
            if mode == .following {
                // For reposts, membership is judged by the reposter (the follow
                // who boosted it), not the original author. The owner's own
                // pubkey is always in followedPubkeys (added by parseContactList),
                // so own posts remain visible. Excluding non-follows here makes an
                // unfollowed author's notes vanish the moment the set changes.
                let author = note.repostedBy ?? note.pubkey
                if !followedPubkeys.contains(author) { return false }
            }
            return showReplies || !note.isReply
        }

        // Popular feed: sort by engagement score instead of chronological
        if mode == .popular && !popularNoteScores.isEmpty {
            filtered.sort { a, b in
                let scoreA = popularNoteScores[a.id] ?? 0
                let scoreB = popularNoteScores[b.id] ?? 0
                if scoreA != scoreB { return scoreA > scoreB }
                return a.createdAt > b.createdAt
            }
        }

        // Apply per-author throttle limits
        if !throttledPubkeys.isEmpty {
            filtered = applyThrottleLimits(filtered, throttledPubkeys: throttledPubkeys)
        }

        return filtered
    }

    /// Filters notes for the media grid view.
    ///
    /// - Parameters:
    ///   - notes: All notes currently in memory.
    ///   - blocked: Hex pubkeys the user has blocked.
    ///   - wotPubkeys: Web-of-Trust pubkey set (for global media filtering).
    ///   - isGlobalMedia: Whether the media tab is in global mode.
    ///   - throttledPubkeys: Authors whose posts are rate-limited.
    /// - Returns: Notes containing media, sorted by date.
    static func filterMediaNotes(
        notes: [FeedNote],
        blocked: Set<String>,
        wotPubkeys: Set<String>,
        isGlobalMedia: Bool,
        throttledPubkeys: [String: Int]
    ) -> [FeedNote] {
        var media = notes.filter { note in
            if blocked.contains(note.pubkey) { return false }
            if isGlobalMedia && !wotPubkeys.isEmpty && !wotPubkeys.contains(note.pubkey) { return false }
            return !note.mediaURLs.isEmpty
        }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id > $1.id
        }

        if !throttledPubkeys.isEmpty {
            media = applyThrottleLimits(media, throttledPubkeys: throttledPubkeys)
        }

        return media
    }

    /// For each throttled author, keeps only their N most recent posts.
    private static func applyThrottleLimits(_ notes: [FeedNote], throttledPubkeys: [String: Int]) -> [FeedNote] {
        var authorCounts: [String: Int] = [:]
        return notes.filter { note in
            guard let maxPosts = throttledPubkeys[note.pubkey] else { return true }
            let count = authorCounts[note.pubkey, default: 0]
            if count < maxPosts {
                authorCounts[note.pubkey] = count + 1
                return true
            }
            return false
        }
    }

    /// Precomputes which notes have their parent as the immediately-next item
    /// in the filtered list. Used to collapse parent/child pairs in the UI.
    static func computeParentIsNext(filteredNotes: [FeedNote]) -> Set<String> {
        var result = Set<String>()
        for i in 0..<filteredNotes.count {
            if let parentId = filteredNotes[i].parentEventId,
               i + 1 < filteredNotes.count,
               filteredNotes[i + 1].id == parentId {
                result.insert(filteredNotes[i].id)
            }
        }
        return result
    }

    // MARK: - WoT Cache

    /// Loads Web-of-Trust pubkeys from the relay's cached `wot_cache.json` file.
    /// The relay computes this graph (owner -> follows -> follows-of-follows) and
    /// persists it to disk. Returns an empty set on any failure.
    static func loadWotPubkeys(from cacheURL: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: cacheURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pubkeys = json["pubkeys"] as? [String: Bool] else {
            return []
        }
        return Set(pubkeys.keys)
    }

    // MARK: - Relay URL Normalization

    /// Normalizes a relay URL string for deduplication (lowercased host, stripped
    /// trailing slash). Returns the lowercased input if parsing fails.
    static func normalizeRelayKey(_ urlStr: String) -> String? {
        guard let url = URL(string: urlStr), let host = url.host else { return urlStr.lowercased() }
        var key = "\(url.scheme ?? "wss")://\(host.lowercased())"
        if let port = url.port { key += ":\(port)" }
        let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        if !path.isEmpty { key += path }
        return key
    }
}
