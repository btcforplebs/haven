import XCTest
@testable import MediaLogic

final class PlayableLinksTests: XCTestCase {
    var dir: URL!
    let fm = FileManager.default
    let sha = String(repeating: "ab", count: 32)

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("PlayableLinksTests-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: dir) }

    private func file(_ name: String, in sub: String = "live/blossom", bytes: String = "bytes") throws -> URL {
        let d = dir.appendingPathComponent(sub)
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        let u = d.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: u)
        return u
    }

    private func isHardLink(_ link: URL, of target: URL) -> Bool {
        PlayableLinks.inspect(link, target: target) == .hardLink
    }

    // The exact production failure: a symlink left by a previous app container.
    // `fileExists` follows it and says false, so the old code hit EEXIST.
    func testDanglingSymlinkIsReplacedNotTrippedOn() throws {
        let target = try file(sha)
        let link = dir.appendingPathComponent("\(sha).mp4")
        try fm.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("gone-container/\(sha)"))
        XCTAssertFalse(fm.fileExists(atPath: link.path), "precondition: fileExists cannot see a dangling link")

        XCTAssertEqual(try PlayableLinks.ensureLink(at: link, to: target), .replaced)
        XCTAssertTrue(isHardLink(link, of: target))
        XCTAssertEqual(try Data(contentsOf: link), Data("bytes".utf8))
    }

    // On the same volume the link must be a HARD link — a symlink is refused
    // by AVFoundation's media daemon on iOS (NSCocoaErrorDomain 257).
    func testFreshLinkIsAHardLinkOnSameVolume() throws {
        let target = try file(sha)
        let link = dir.appendingPathComponent("\(sha).mov")
        XCTAssertEqual(try PlayableLinks.ensureLink(at: link, to: target), .created)
        let attrs = try fm.attributesOfItem(atPath: link.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeRegular)
        XCTAssertTrue(isHardLink(link, of: target))
        XCTAssertEqual(try Data(contentsOf: link), Data("bytes".utf8))
    }

    func testExistingHardLinkIsReused() throws {
        let target = try file(sha)
        let link = dir.appendingPathComponent("\(sha).mp4")
        XCTAssertEqual(try PlayableLinks.ensureLink(at: link, to: target), .created)
        XCTAssertEqual(try PlayableLinks.ensureLink(at: link, to: target), .reused)
    }

    // A link to a DIFFERENT blob under the same name (cache/ copy vs blossom/
    // copy, or a rewritten blob) must be repointed or the player gets stale bytes.
    func testHardLinkToOtherInodeIsReplaced() throws {
        let a = try file(sha, in: "live/cache", bytes: "old")
        let b = try file(sha, in: "live/blossom", bytes: "new")
        let link = dir.appendingPathComponent("\(sha).mp4")
        XCTAssertEqual(try PlayableLinks.ensureLink(at: link, to: a), .created)
        XCTAssertEqual(try PlayableLinks.ensureLink(at: link, to: b), .replaced)
        XCTAssertTrue(isHardLink(link, of: b))
        XCTAssertEqual(try Data(contentsOf: link), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: a), Data("old".utf8), "replacing the link must not touch the old blob")
    }

    func testLiveSymlinkToSameTargetIsKeptAndToOtherTargetReplaced() throws {
        let a = try file(sha, in: "live/cache")
        let b = try file(sha, in: "live/blossom")
        let link = dir.appendingPathComponent("\(sha).mp4")
        try fm.createSymbolicLink(at: link, withDestinationURL: a)
        XCTAssertEqual(try PlayableLinks.ensureLink(at: link, to: a), .reused, "a working symlink is left alone (macOS cross-volume case)")
        XCTAssertEqual(try PlayableLinks.ensureLink(at: link, to: b), .replaced)
        XCTAssertTrue(isHardLink(link, of: b))
    }

    func testInspectDistinguishesEveryState() throws {
        let target = try file(sha)
        let hard = dir.appendingPathComponent("hard.mp4")
        let live = dir.appendingPathComponent("live.mp4")
        let dangling = dir.appendingPathComponent("dangling.mp4")
        let plain = dir.appendingPathComponent("plain.mp4")
        let folder = dir.appendingPathComponent("folder.mp4")
        try fm.linkItem(at: target, to: hard)
        try fm.createSymbolicLink(at: live, withDestinationURL: target)
        try fm.createSymbolicLink(at: dangling, withDestinationURL: dir.appendingPathComponent("nope"))
        try Data().write(to: plain)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(PlayableLinks.inspect(hard, target: target), .hardLink)
        XCTAssertEqual(PlayableLinks.inspect(hard), .otherFile, "without a target a hard link is just a file")
        XCTAssertEqual(PlayableLinks.inspect(live), .liveLink(destination: target.path))
        XCTAssertEqual(PlayableLinks.inspect(dangling), .danglingLink(destination: dir.appendingPathComponent("nope").path))
        XCTAssertEqual(PlayableLinks.inspect(plain, target: target), .otherFile)
        XCTAssertEqual(PlayableLinks.inspect(folder), .other)
        XCTAssertEqual(PlayableLinks.inspect(dir.appendingPathComponent("absent.mp4")), .absent)
    }

    func testIsOursMatchesOnlyOurNamingSchemes() {
        XCTAssertTrue(PlayableLinks.isOurs("\(sha).mp4"))
        XCTAssertTrue(PlayableLinks.isOurs("\(sha).webm"))
        XCTAssertTrue(PlayableLinks.isOurs("thumb_\(UUID().uuidString).mov"))
        XCTAssertFalse(PlayableLinks.isOurs(sha), "bare hash without extension is a blob, not a link")
        XCTAssertFalse(PlayableLinks.isOurs("CFNetworkDownload_2R0xx5.tmp"))
        XCTAssertFalse(PlayableLinks.isOurs("TemporaryItems"))
        XCTAssertFalse(PlayableLinks.isOurs("\(sha.dropLast()).mp4"))
    }

    // Launch sweep: removes links into dead or foreign containers, hard links
    // whose blob is gone, and legacy one-off thumbnails; keeps live links
    // under the current store; never touches files that are not ours.
    func testPurgeStaleRemovesOnlyDeadOrForeignLinks() throws {
        let liveRoot = dir.appendingPathComponent("live")
        let liveBlob = try file(sha, in: "live/blossom")
        let cacheSha = String(repeating: "ef", count: 32)
        let cacheBlob = try file(cacheSha, in: "live/cache")
        let foreignBlob = try file(sha, in: "other-container/blossom")
        let tmp = dir.appendingPathComponent("tmp")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let keepHard = tmp.appendingPathComponent("\(sha).mp4")
        let keepCacheHard = tmp.appendingPathComponent("\(cacheSha).mov")
        let keepSym = tmp.appendingPathComponent("\(sha).m4v")
        let deadSym = tmp.appendingPathComponent("\(String(repeating: "cd", count: 32)).mov")
        let foreignSym = tmp.appendingPathComponent("\(sha).webm")
        let orphanHard = tmp.appendingPathComponent("\(String(repeating: "12", count: 32)).mp4")
        let legacyThumb = tmp.appendingPathComponent("thumb_\(UUID().uuidString).mp4")
        let notOurs = tmp.appendingPathComponent("someone-elses-link.mp4")
        let download = tmp.appendingPathComponent("CFNetworkDownload_x.tmp")

        try fm.linkItem(at: liveBlob, to: keepHard)
        try fm.linkItem(at: cacheBlob, to: keepCacheHard)
        try fm.createSymbolicLink(at: keepSym, withDestinationURL: liveBlob)
        try fm.createSymbolicLink(at: deadSym, withDestinationURL: dir.appendingPathComponent("gone/\(sha)"))
        try fm.createSymbolicLink(at: foreignSym, withDestinationURL: foreignBlob)
        let deletedBlob = try file("deleted", in: "live/blossom")
        try fm.linkItem(at: deletedBlob, to: orphanHard)
        try fm.removeItem(at: deletedBlob)
        try fm.createSymbolicLink(at: legacyThumb, withDestinationURL: liveBlob)
        try fm.createSymbolicLink(at: notOurs, withDestinationURL: dir.appendingPathComponent("gone/x"))
        try Data("dl".utf8).write(to: download)

        let removed = PlayableLinks.purgeStale(in: tmp, liveRoot: liveRoot)

        XCTAssertEqual(removed, 4)
        XCTAssertTrue(isHardLink(keepHard, of: liveBlob))
        XCTAssertTrue(isHardLink(keepCacheHard, of: cacheBlob))
        XCTAssertEqual(PlayableLinks.inspect(keepSym), .liveLink(destination: liveBlob.path))
        XCTAssertEqual(PlayableLinks.inspect(deadSym), .absent)
        XCTAssertEqual(PlayableLinks.inspect(foreignSym), .absent)
        XCTAssertEqual(PlayableLinks.inspect(orphanHard), .absent)
        XCTAssertEqual(PlayableLinks.inspect(legacyThumb), .absent)
        XCTAssertEqual(PlayableLinks.inspect(notOurs), .danglingLink(destination: dir.appendingPathComponent("gone/x").path))
        XCTAssertEqual(try Data(contentsOf: download), Data("dl".utf8))
    }

    func testPurgeOnMissingDirectoryIsANoOp() {
        XCTAssertEqual(PlayableLinks.purgeStale(in: dir.appendingPathComponent("nope"), liveRoot: dir), 0)
    }
}
