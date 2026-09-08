import XCTest
@testable import MediaLogic

final class LinkPreviewCacheKeyTests: XCTestCase {

    private func key(_ string: String) -> String {
        LinkPreviewCacheKey.filename(for: URL(string: string)!)
    }

    /// The bug this key exists to prevent: two links that differ only after a
    /// long shared prefix must not land in the same cache file. The previous
    /// implementation kept the first 32 characters of the URL, so every one of
    /// these pairs collided and the second link showed the first one's preview.
    func testLinksSharingALongPrefixGetDifferentKeys() {
        let pairs = [
            ("https://testflight.apple.com/join/AbCdEf12", "https://testflight.apple.com/join/ZZ99YY88"),
            ("https://github.com/btcforplebs/nostr-vault/pull/1", "https://github.com/btcforplebs/nostr-vault/pull/2"),
            ("https://www.youtube.com/watch?v=aaaaaaaaaaa", "https://www.youtube.com/watch?v=bbbbbbbbbbb"),
        ]
        for (first, second) in pairs {
            XCTAssertNotEqual(key(first), key(second), "collision between \(first) and \(second)")
        }
    }

    func testDifferenceInTheLastCharacterChangesTheKey() {
        XCTAssertNotEqual(key("https://example.com/a"), key("https://example.com/b"))
    }

    func testSameURLGivesTheSameKey() {
        XCTAssertEqual(key("https://example.com/a"), key("https://example.com/a"))
    }

    /// A filename, not a path: a URL's slashes must not create directories.
    func testKeyIsASingleFilename() {
        let name = key("https://example.com/deep/path/with/slashes?q=1")
        XCTAssertFalse(name.contains("/"))
        XCTAssertEqual(name.count, 64 + ".json".count)
        XCTAssertTrue(name.hasSuffix(".json"))
    }
}
