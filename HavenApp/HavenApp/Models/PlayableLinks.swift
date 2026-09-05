import Foundation

/// Manages the temp-directory links that give extensionless Blossom blobs a
/// container extension AVFoundation will open.
///
/// Two things this type exists to get right, both learned on device 2026-09-03:
///
/// 1. On iOS every install (TestFlight, `devicectl install`, App Store update)
///    moves the app into a NEW data container while carrying `tmp/` along. A
///    symlink created before the move keeps pointing at the old, now
///    unreadable container. Such a link is invisible to
///    `FileManager.fileExists(atPath:)` — it follows the link and reports
///    false — so "remove if exists, then create" tripped on EEXIST and the
///    player lost its local candidate for every video on the phone.
///
/// 2. Even a correct symlink is not enough on iOS: AVFoundation opens media in
///    a separate daemon whose sandbox grant covers the path it was handed, not
///    the path the link resolves to, so playback through a symlink fails with
///    NSCocoaErrorDomain 257 (no permission). A HARD link is a real directory
///    entry for the blob's inode and plays. Symlinks remain the fallback for
///    the cross-volume case (macOS with the Blossom store on another disk).
///
/// Pure Foundation, no AVFoundation, so it is unit-testable against a temp dir.
enum PlayableLinks {

    /// What `ensureLink` decided to do. Returned for logging and tests.
    enum Outcome: Equatable {
        /// A link already pointed at the wanted target and the target is readable.
        case reused
        /// Something else sat at the link path (dangling link, link to another
        /// target, foreign file); it was removed and a fresh link created.
        case replaced
        /// Nothing was at the link path; a link was created.
        case created
    }

    enum Entry: Equatable {
        case absent
        /// A hard link (or the file itself) sharing `target`'s inode.
        case hardLink
        /// A regular file that is NOT the target's inode — stale or foreign.
        case otherFile
        /// Symlink whose destination currently exists and is readable.
        case liveLink(destination: String)
        /// Symlink whose destination cannot be reached (deleted, or in a
        /// container the sandbox no longer lets us read).
        case danglingLink(destination: String)
        /// A directory or something else we will not touch.
        case other
    }

    /// Makes `link` open `target`'s bytes under `link`'s name, replacing
    /// whatever is there unless it already does exactly that. Prefers a hard
    /// link; falls back to a symlink when the two paths are on different
    /// volumes. Uses lstat semantics throughout so a dangling link is seen and
    /// removed rather than tripped on.
    @discardableResult
    static func ensureLink(at link: URL, to target: URL, fileManager fm: FileManager = .default) throws -> Outcome {
        let existing = inspect(link, target: target, fileManager: fm)
        switch existing {
        case .hardLink:
            return .reused
        case .liveLink(let destination) where destination == target.path:
            return .reused
        case .absent:
            try create(link: link, to: target, fileManager: fm)
            return .created
        case .liveLink, .danglingLink, .otherFile, .other:
            try fm.removeItem(at: link)
            try create(link: link, to: target, fileManager: fm)
            return .replaced
        }
    }

    private static func create(link: URL, to target: URL, fileManager fm: FileManager) throws {
        do {
            try fm.linkItem(at: target, to: link)
        } catch {
            // EXDEV (different volume) or a filesystem without hard links:
            // a symlink still works wherever the opener is the app itself.
            try fm.createSymbolicLink(at: link, withDestinationURL: target)
        }
    }

    /// lstat-style inspection: never follows a symlink when deciding whether
    /// something is there. `target` is needed to recognise a hard link, since
    /// a hard link is indistinguishable from any other file without it.
    static func inspect(_ link: URL, target: URL? = nil, fileManager fm: FileManager = .default) -> Entry {
        guard let attrs = try? fm.attributesOfItem(atPath: link.path) else {
            return .absent
        }
        switch attrs[.type] as? FileAttributeType {
        case .typeSymbolicLink?:
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) else {
                return .other
            }
            // `fileExists` follows the link; false means the target is gone or
            // unreadable. `isReadableFile` additionally catches a target that
            // exists but the sandbox refuses.
            if fm.fileExists(atPath: destination), fm.isReadableFile(atPath: destination) {
                return .liveLink(destination: destination)
            }
            return .danglingLink(destination: destination)
        case .typeRegular?:
            if let target, let targetAttrs = try? fm.attributesOfItem(atPath: target.path),
               sameInode(attrs, targetAttrs) {
                return .hardLink
            }
            return .otherFile
        default:
            return .other
        }
    }

    private static func sameInode(_ a: [FileAttributeKey: Any], _ b: [FileAttributeKey: Any]) -> Bool {
        guard let ia = a[.systemFileNumber] as? UInt64 ?? (a[.systemFileNumber] as? Int).map(UInt64.init),
              let ib = b[.systemFileNumber] as? UInt64 ?? (b[.systemFileNumber] as? Int).map(UInt64.init),
              let da = a[.systemNumber] as? Int, let db = b[.systemNumber] as? Int else { return false }
        return ia == ib && da == db
    }

    /// Names this type creates: `<sha256>.<ext>` playback links (the stem is
    /// the blob's file name in blossom/ or cache/). `thumb_<uuid>.<ext>` is the
    /// legacy one-off thumbnail scheme, kept only so the sweep can remove it.
    static func isOurs(_ name: String) -> Bool {
        if name.hasPrefix("thumb_") { return true }
        let stem = (name as NSString).deletingPathExtension
        return stem.count == 64 && stem.allSatisfy { $0.isHexDigit } && !(name as NSString).pathExtension.isEmpty
    }

    /// Where a `<sha256>.<ext>` link's blob may live under the current store.
    static let blobSubdirectories = ["blossom", "cache"]

    /// Deletes every link of ours in `directory` that does not open a blob
    /// under `liveRoot` (the current haven_database directory): symlinks into
    /// dead or foreign containers, hard links whose blob is gone, and every
    /// legacy one-off thumbnail link. Files we did not create are left alone.
    /// Returns the number of entries removed.
    @discardableResult
    static func purgeStale(in directory: URL, liveRoot: URL, fileManager fm: FileManager = .default) -> Int {
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return 0 }
        let root = liveRoot.standardizedFileURL.path
        var removed = 0
        for name in names where isOurs(name) {
            let link = directory.appendingPathComponent(name)
            if name.hasPrefix("thumb_") {
                if (try? fm.removeItem(at: link)) != nil { removed += 1 }
                continue
            }
            let stem = (name as NSString).deletingPathExtension
            let candidates = blobSubdirectories.map { liveRoot.appendingPathComponent($0).appendingPathComponent(stem) }
            var keep = false
            switch inspect(link, fileManager: fm) {
            case .liveLink(let destination):
                let dest = URL(fileURLWithPath: destination).standardizedFileURL.path
                keep = dest.hasPrefix(root + "/")
            case .otherFile:
                // A hard link is only worth keeping while its blob is still in
                // the store; otherwise it pins deleted bytes forever.
                keep = candidates.contains { inspect(link, target: $0, fileManager: fm) == .hardLink }
            case .danglingLink:
                keep = false
            case .absent, .hardLink, .other:
                continue
            }
            if !keep, (try? fm.removeItem(at: link)) != nil { removed += 1 }
        }
        return removed
    }
}
