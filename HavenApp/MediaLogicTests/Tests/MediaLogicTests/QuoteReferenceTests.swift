import XCTest
@testable import MediaLogic

final class QuoteReferenceTests: XCTestCase {

    // MARK: - Finding references in content

    func testFindsEachKindOfReference() {
        let content = """
        look at nostr:note1abc123 and nostr:nevent1def456 \
        and the article nostr:naddr1ghi789
        """
        XCTAssertEqual(
            QuoteReference.identifiers(in: content),
            ["note1abc123", "nevent1def456", "naddr1ghi789"]
        )
    }

    func testIgnoresProfileReferencesAndBareText() {
        let content = "hey nostr:npub1abc and nostr:nprofile1def, note1notprefixed"
        XCTAssertEqual(QuoteReference.identifiers(in: content), [])
    }

    /// The identifiers address rows in a list, so the same reference twice must
    /// not become two cards with the same SwiftUI id.
    func testRepeatedReferenceIsListedOnce() {
        let content = "nostr:note1abc … and again nostr:note1abc"
        XCTAssertEqual(QuoteReference.identifiers(in: content), ["note1abc"])
    }

    func testOrderIsPreserved() {
        let content = "nostr:nevent1zzz first, nostr:note1aaa second"
        XCTAssertEqual(QuoteReference.identifiers(in: content), ["nevent1zzz", "note1aaa"])
    }

    // MARK: - nevent TLV

    func testEventIDFromNeventPayload() {
        let id = Data((0..<32).map { UInt8($0) })
        var payload = Data([1, 4]) + Data([1, 2, 3, 4])   // type 1 (relay), skipped
        payload += Data([0, 32]) + id                      // type 0 (event id)
        XCTAssertEqual(
            QuoteReference.eventID(fromNeventTLV: payload),
            id.map { String(format: "%02x", $0) }.joined()
        )
    }

    func testEventIDRejectsWrongLengthAndTruncatedPayloads() {
        // Type 0 but only 16 bytes — not an event id.
        XCTAssertNil(QuoteReference.eventID(fromNeventTLV: Data([0, 16]) + Data(repeating: 7, count: 16)))
        // Claims 32 bytes, carries 4.
        XCTAssertNil(QuoteReference.eventID(fromNeventTLV: Data([0, 32]) + Data([1, 2, 3, 4])))
        XCTAssertNil(QuoteReference.eventID(fromNeventTLV: Data()))
    }

    // MARK: - naddr TLV

    func testCoordinateFromNaddrPayload() {
        let pubkey = Data(repeating: 0xab, count: 32)
        var payload = Data([0, 5]) + Data("intro".utf8)                 // d-tag
        payload += Data([2, 32]) + pubkey                                // pubkey
        payload += Data([3, 4]) + Data([0x00, 0x00, 0x75, 0x53])         // kind 30035
        XCTAssertEqual(
            QuoteReference.coordinate(fromNaddrTLV: payload),
            "naddr:30035:\(String(repeating: "ab", count: 32)):intro"
        )
    }

    /// Kind is four big-endian bytes. Reading them the other way round turns
    /// 30023 into 2489745408 and the fetch filter then matches nothing.
    func testKindIsReadBigEndian() {
        let pubkey = Data(repeating: 0x11, count: 32)
        var payload = Data([2, 32]) + pubkey
        payload += Data([3, 4]) + Data([0x00, 0x00, 0x75, 0x47])         // 30023
        let coordinate = QuoteReference.coordinate(fromNaddrTLV: payload)
        XCTAssertEqual(QuoteReference.parseCoordinate(coordinate ?? "")?.kind, 30023)
    }

    func testCoordinateNeedsKindAndPubkey() {
        // d-tag only — names no event.
        XCTAssertNil(QuoteReference.coordinate(fromNaddrTLV: Data([0, 5]) + Data("intro".utf8)))
        // kind but no pubkey.
        XCTAssertNil(QuoteReference.coordinate(fromNaddrTLV: Data([3, 4]) + Data([0, 0, 0x75, 0x47])))
    }

    func testEmptyDTagIsAllowed() {
        var payload = Data([2, 32]) + Data(repeating: 0x22, count: 32)
        payload += Data([3, 4]) + Data([0, 0, 0x75, 0x47])
        let coordinate = QuoteReference.coordinate(fromNaddrTLV: payload)
        XCTAssertEqual(QuoteReference.parseCoordinate(coordinate ?? "")?.dTag, "")
    }

    // MARK: - Coordinate round trip

    func testCoordinateRoundTrip() {
        let built = QuoteReference.coordinate(kind: 30023, pubkey: "deadbeef", dTag: "my-post")
        let parsed = QuoteReference.parseCoordinate(built)
        XCTAssertEqual(parsed?.kind, 30023)
        XCTAssertEqual(parsed?.pubkey, "deadbeef")
        XCTAssertEqual(parsed?.dTag, "my-post")
    }

    /// A d-tag may contain colons; splitting on all of them loses the tail.
    func testDTagKeepsItsColons() {
        let built = QuoteReference.coordinate(kind: 30023, pubkey: "deadbeef", dTag: "2026:09:08-notes")
        XCTAssertEqual(QuoteReference.parseCoordinate(built)?.dTag, "2026:09:08-notes")
    }

    func testPlainEventIDIsNotACoordinate() {
        XCTAssertNil(QuoteReference.parseCoordinate(String(repeating: "a", count: 64)))
        XCTAssertNil(QuoteReference.parseCoordinate("naddr:notanumber:pk:d"))
        XCTAssertNil(QuoteReference.parseCoordinate("naddr:30023::d"))
    }
}
