import Foundation

/// What the Following feed should put on screen right now.
///
/// Its own file, free of every other type, because the rule below is the whole
/// fix for a bug that shipped for months and it needs to be testable — the
/// MediaLogicTests package can compile a Foundation-only source directly, and
/// ContactManager (its natural home) drags in Bech32 and cannot be compiled
/// alone.
enum FollowingFeedState {

    /// What belongs on screen for a follow-set feed right now.
    enum Placeholder: Equatable {
        /// Notes (or an honest empty list) — we know enough to render.
        case feed
        /// We do not know the follow set yet. Never accuse the user of
        /// following nobody while this is the answer.
        case loading
        /// The follow set is genuinely empty and that has been established.
        case empty
    }

    /// The rule that keeps "You aren't following anyone" from flashing on every
    /// cold launch.
    ///
    /// "No follows" is a *conclusion*, and it needs evidence: a contact load
    /// that actually finished. Before this function existed, the view inferred
    /// it from `followedPubkeys.isEmpty && !isLoadingContacts && !isLoadingFeed`
    /// — three flags that are all trivially true in the seconds before anything
    /// has started loading, which is exactly when the user is looking.
    ///
    /// - Parameters:
    ///   - hasAttemptedContactLoad: a contact load has run to a conclusion
    ///     (success, empty, or timeout) for this account. The load-bearing input.
    ///   - hasNotes: cached notes are already on screen, so whatever the follow
    ///     set turns out to be, replacing them with a placeholder is wrong.
    static func decide(
        followCount: Int,
        hasAttemptedContactLoad: Bool,
        isLoadingContacts: Bool,
        isLoadingFeed: Bool,
        hasNotes: Bool
    ) -> Placeholder {
        // Content on screen outranks everything: whatever the follow set turns
        // out to be, covering readable notes with a placeholder is wrong.
        if hasNotes { return .feed }
        if isLoadingContacts || isLoadingFeed { return .loading }
        // Nothing on screen and nothing resolved yet. A follow set seeded from
        // the local backup is a good guess, not an answer, so this is still
        // "loading" rather than an empty feed that looks like nobody posted.
        if !hasAttemptedContactLoad { return .loading }
        return followCount > 0 ? .feed : .empty
    }
}
