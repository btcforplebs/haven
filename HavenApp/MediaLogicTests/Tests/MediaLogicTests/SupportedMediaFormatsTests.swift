import XCTest
@testable import MediaLogic

/// Every media type the app claims to support must classify the same way from
/// its extension and from its MIME type, and round-trip MIME -> extension.
final class SupportedMediaFormatsTests: XCTestCase {

    func testEveryEntryClassifiesConsistentlyByExtensionAndMime() {
        for entry in SupportedMediaFormats.all {
            XCTAssertEqual(SupportedMediaFormats.category(forExtension: entry.ext), entry.category, entry.ext)
            XCTAssertEqual(SupportedMediaFormats.category(forExtension: entry.ext.uppercased()), entry.category, entry.ext)
            XCTAssertEqual(SupportedMediaFormats.category(forMime: entry.mime), entry.category, entry.mime)
            XCTAssertEqual(SupportedMediaFormats.mime(forExtension: entry.ext), entry.mime, entry.ext)
            XCTAssertNotNil(SupportedMediaFormats.extension(forMime: entry.mime), entry.mime)
        }
    }

    func testVideoContainersTheRelayServesAreAllVideo() {
        // Mirrors haven-go blossomExtTypes: what the relay labels as video the
        // app must treat as video, or the media tab shows a document icon.
        for ext in ["mp4", "m4v", "mov", "webm"] {
            XCTAssertTrue(SupportedMediaFormats.videoExtensions.contains(ext), ext)
            XCTAssertTrue(URL(string: "https://127.0.0.1:3355/\(String(repeating: "a", count: 64)).\(ext)")!.isVideo, ext)
        }
        for ext in ["mp3", "m4a", "wav"] {
            XCTAssertTrue(SupportedMediaFormats.audioExtensions.contains(ext), ext)
        }
        for ext in ["gif", "jpg", "jpeg", "png", "webp", "avif"] {
            XCTAssertTrue(SupportedMediaFormats.imageOrGifExtensions.contains(ext), ext)
        }
    }

    func testMimeParametersAndAliasesResolve() {
        XCTAssertEqual(SupportedMediaFormats.extension(forMime: "video/mp4; codecs=avc1"), "mp4")
        XCTAssertEqual(SupportedMediaFormats.extension(forMime: "VIDEO/QUICKTIME"), "mov")
        XCTAssertEqual(SupportedMediaFormats.extension(forMime: "video/mov"), "mov")
        XCTAssertEqual(SupportedMediaFormats.extension(forMime: "audio/x-m4a"), "m4a")
        XCTAssertNil(SupportedMediaFormats.extension(forMime: "application/octet-stream"))
        XCTAssertNil(SupportedMediaFormats.category(forMime: "application/octet-stream"))
    }

    func testExtensionlessBlossomHashCountsAsImageCandidateOnly() {
        let hash = String(repeating: "f", count: 64)
        let bare = URL(string: "https://127.0.0.1:3355/\(hash)")!
        XCTAssertTrue(bare.isImage, "bare hash is a media candidate until sniffed")
        XCTAssertFalse(bare.isVideo)
        XCTAssertFalse(bare.isGIF)
    }

    func testMediaURLRegexMatchesExtensionAndBlossomForms() throws {
        let regex = try XCTUnwrap(SupportedMediaFormats.mediaURLRegex)
        let hash = String(repeating: "0", count: 64)
        let text = "see https://a.b/c.MOV and https://x.y/\(hash) plus https://x.y/blossom/\(hash) and https://x.y/page.html"
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        XCTAssertEqual(matches.count, 3)
    }
}
