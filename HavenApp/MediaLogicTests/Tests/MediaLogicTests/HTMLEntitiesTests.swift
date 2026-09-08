import XCTest
@testable import MediaLogic

final class HTMLEntitiesTests: XCTestCase {

    func testNamedEntities() {
        XCTAssertEqual(HTMLEntities.decode("Bob&#39;s blog"), "Bob's blog")
        XCTAssertEqual(HTMLEntities.decode("Rock &amp; Roll"), "Rock & Roll")
        XCTAssertEqual(HTMLEntities.decode("&lt;title&gt;"), "<title>")
        XCTAssertEqual(HTMLEntities.decode("&quot;quoted&quot;"), "\"quoted\"")
        XCTAssertEqual(HTMLEntities.decode("caf&eacute;"), "caf&eacute;")   // not in the table: left alone
    }

    func testNumericEntities() {
        XCTAssertEqual(HTMLEntities.decode("&#8212;dash"), "—dash")
        XCTAssertEqual(HTMLEntities.decode("&#x2014;dash"), "—dash")
        XCTAssertEqual(HTMLEntities.decode("&#X2014;dash"), "—dash")
        XCTAssertEqual(HTMLEntities.decode("emoji &#128512;"), "emoji 😀")
    }

    /// A bare "&" in a title is ordinary prose, not a broken entity — it must
    /// survive untouched, and it must not swallow the text that follows it.
    func testBareAmpersandIsKept() {
        XCTAssertEqual(HTMLEntities.decode("Fish & chips"), "Fish & chips")
        XCTAssertEqual(HTMLEntities.decode("A & B &amp; C"), "A & B & C")
        XCTAssertEqual(HTMLEntities.decode("&"), "&")
        XCTAssertEqual(HTMLEntities.decode("ends with &"), "ends with &")
    }

    /// An unknown or malformed reference is left exactly as it arrived rather
    /// than dropped — a wrong character beats a missing one.
    func testUnknownReferencesAreLeftAlone() {
        XCTAssertEqual(HTMLEntities.decode("&notanentity;"), "&notanentity;")
        XCTAssertEqual(HTMLEntities.decode("&#99999999999;"), "&#99999999999;")
        XCTAssertEqual(HTMLEntities.decode("&#xD800;"), "&#xD800;")   // lone surrogate
        XCTAssertEqual(HTMLEntities.decode("&;"), "&;")
    }

    func testTextWithoutEntitiesIsUnchanged() {
        XCTAssertEqual(HTMLEntities.decode("A plain title"), "A plain title")
        XCTAssertEqual(HTMLEntities.decode(""), "")
    }

    func testMultipleEntitiesInOneString() {
        XCTAssertEqual(
            HTMLEntities.decode("&ldquo;It&rsquo;s fine&rdquo; &mdash; Bob &amp; Co&hellip;"),
            "“It’s fine” — Bob & Co…"
        )
    }
}
