import XCTest
@testable import MediaLogic

/// The bug these exist for: on every cold launch the Following feed showed
/// "You aren't following anyone" with a Refresh button for about three
/// seconds, because the cold-start load is gated on relay readiness (three
/// seconds after the relay reports running) and nothing had started yet.
final class FollowingPlaceholderTests: XCTestCase {

    /// The launch window itself: nothing loaded, nothing loading, nothing
    /// attempted. This must never be `.empty`.
    func testBeforeAnyContactLoadWeWaitRatherThanAccuse() {
        XCTAssertEqual(
            FollowingFeedState.decide(followCount: 0,
                                                hasAttemptedContactLoad: false,
                                                isLoadingContacts: false,
                                                isLoadingFeed: false,
                                                hasNotes: false),
            .loading
        )
    }

    /// A user who genuinely follows nobody still has to be told, or the app
    /// spins forever with no way forward.
    func testEmptyFollowSetAfterAResolvedLoadIsReported() {
        XCTAssertEqual(
            FollowingFeedState.decide(followCount: 0,
                                                hasAttemptedContactLoad: true,
                                                isLoadingContacts: false,
                                                isLoadingFeed: false,
                                                hasNotes: false),
            .empty
        )
    }

    func testResolvedFollowsWithNothingToShowIsAnEmptyFeedNotAPlaceholder() {
        XCTAssertEqual(
            FollowingFeedState.decide(followCount: 12,
                                      hasAttemptedContactLoad: true,
                                      isLoadingContacts: false,
                                      isLoadingFeed: false,
                                      hasNotes: false),
            .feed
        )
    }

    /// Follows seeded from the local backup are a good guess, not an answer.
    /// With nothing on screen and no resolved load, "loading" is the honest
    /// state — an empty feed here reads as "nobody you follow has posted".
    func testSeededFollowsBeforeAResolvedLoadStillShowLoading() {
        XCTAssertEqual(
            FollowingFeedState.decide(followCount: 12,
                                      hasAttemptedContactLoad: false,
                                      isLoadingContacts: false,
                                      isLoadingFeed: false,
                                      hasNotes: false),
            .loading
        )
    }

    /// Cached notes restored from disk outrank every other signal: whatever the
    /// follow set turns out to be, covering readable content with a placeholder
    /// is the wrong move.
    func testCachedNotesAreNeverCoveredByAPlaceholder() {
        XCTAssertEqual(
            FollowingFeedState.decide(followCount: 0,
                                                hasAttemptedContactLoad: true,
                                                isLoadingContacts: true,
                                                isLoadingFeed: true,
                                                hasNotes: true),
            .feed
        )
    }

    func testLoadingInFlightShowsLoading() {
        XCTAssertEqual(
            FollowingFeedState.decide(followCount: 0,
                                                hasAttemptedContactLoad: false,
                                                isLoadingContacts: true,
                                                isLoadingFeed: false,
                                                hasNotes: false),
            .loading
        )
        XCTAssertEqual(
            FollowingFeedState.decide(followCount: 0,
                                                hasAttemptedContactLoad: false,
                                                isLoadingContacts: false,
                                                isLoadingFeed: true,
                                                hasNotes: false),
            .loading
        )
    }

    /// A finished load that found nothing, with a retry already in flight,
    /// should not flip back to the accusation mid-retry.
    func testResolvedButRetryingShowsLoading() {
        XCTAssertEqual(
            FollowingFeedState.decide(followCount: 0,
                                                hasAttemptedContactLoad: true,
                                                isLoadingContacts: true,
                                                isLoadingFeed: false,
                                                hasNotes: false),
            .loading
        )
    }

    /// The exhaustive statement of the rule: `.empty` requires a resolved load.
    func testEmptyIsUnreachableWithoutAResolvedLoad() {
        for loadingContacts in [true, false] {
            for loadingFeed in [true, false] {
                for hasNotes in [true, false] {
                    let result = FollowingFeedState.decide(
                        followCount: 0,
                        hasAttemptedContactLoad: false,
                        isLoadingContacts: loadingContacts,
                        isLoadingFeed: loadingFeed,
                        hasNotes: hasNotes)
                    XCTAssertNotEqual(result, .empty,
                                      "empty claimed with no resolved contact load")
                }
            }
        }
    }
}
