import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
import WidgetKit

// MARK: - Widget Bridge
//
// The app half of the widget contract: gather what the widgets draw, write it
// to the shared keychain item, and ask WidgetKit to reload.
//
// Runs on the main actor because every source it reads is a @MainActor
// ObservableObject. It is cheap -- a few array reads and one keychain write --
// and it is rate limited below, because scene activation can fire in bursts.

@MainActor
enum NVWidgetBridge {
    /// WidgetKit only budgets so many reloads per day. Refusing to republish
    /// more than once a minute keeps a chatty caller from spending that budget
    /// on identical snapshots.
    private static var lastPublished: Date = .distantPast
    private static let minimumInterval: TimeInterval = 60

    static func publish(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastPublished) >= minimumInterval else { return }
        lastPublished = Date()

        let snapshot = buildSnapshot()
        guard NVSharedStore.save(snapshot) else { return }
        WidgetCenter.shared.reloadAllTimelines()
        publishThumbnails(for: snapshot.media)
    }

    private static func buildSnapshot() -> NVWidgetSnapshot {
        let config = ConfigService.shared
        let feed = FeedService.shared
        let nostr = NostrService.shared
        let relay = RelayProcessManager.shared
        let stats = StatsService.shared

        let me = config.activeAccountHexPubkey
        let recent = Array(feed.notes.prefix(40))

        return NVWidgetSnapshot(
            generatedAt: Date(),
            relay: .init(
                isRunning: relay.isRunning,
                eventCount: stats.loadedEventsCount,
                storageBytes: stats.storageSize,
                connectionCount: relay.activeConnections,
                uptimeSeconds: relay.isRunning ? Int(Date().timeIntervalSince(processStart)) : 0
            ),
            feed: recent.prefix(10).map { note($0, nostr: nostr) },
            mentions: recent.filter { mentions(me, $0) }.prefix(10).map { note($0, nostr: nostr) },
            wallet: .init(
                cashuSats: Int(CashuService.shared.balanceSats),
                lightningSats: nil,   // no published NWC balance to read yet
                zapsReceived24h: 0,   // no published zap tally to read yet
                btcPriceUSD: nil      // the app does not fetch a price
            ),
            media: mediaTiles(recent: recent, me: me),
            unreadDMCount: DMService.shared.totalUnreadCount
        )
    }

    private static let processStart = Date()

    /// Mosaic's tiles, newest first.
    ///
    /// Blossom first — those are the blobs actually on your relay, which is what
    /// the widget claims to show. Media from recent notes fills in behind it, so
    /// a vault with nothing uploaded yet still draws something rather than an
    /// empty grid. The two are deduped by URL because your own uploads normally
    /// appear in both.
    private static func mediaTiles(recent: [FeedNote], me: String) -> [NVWidgetSnapshot.MediaTile] {
        var tiles: [NVWidgetSnapshot.MediaTile] = []
        var seen = Set<String>()

        for item in BlossomMediaCache.shared.items.sorted(by: { $0.dateAdded > $1.dateAdded }) {
            guard seen.insert(item.url.absoluteString).inserted else { continue }
            tiles.append(.init(id: item.url.lastPathComponent, url: item.url, kind: kind(of: item)))
            if tiles.count >= maxTiles { return tiles }
        }

        for note in recent where note.pubkey == me {
            for url in note.mediaURLs {
                guard seen.insert(url.absoluteString).inserted else { continue }
                // Note media carries no sniffed mime, and the filter chips would
                // rather show a tile under "All" only than mislabel it.
                tiles.append(.init(id: note.id + url.absoluteString, url: url, kind: nil))
                if tiles.count >= maxTiles { return tiles }
            }
        }
        return tiles
    }

    private static let maxTiles = 18

    /// The gallery's media types collapsed onto the four the widget filters by.
    /// GIF is its own chip in the Media tab, so it is its own kind here.
    private static func kind(of item: MediaItem) -> NVMediaKind {
        if item.isAnimatedGIF { return .gif }
        switch item.type {
        case .image: return .image
        case .video: return .video
        case .audio, .unknown: return .other
        }
    }

    /// Shrinks whatever Blossom holds on disk into tiles the widget can draw
    /// without a network or a running relay.
    ///
    /// Only local files are done here. Remote media (someone else's host) is
    /// left to the widget's own timeline provider, which does have a network and
    /// a few seconds to use it — unlike the widget's body, which has neither.
    private static func publishThumbnails(for tiles: [NVWidgetSnapshot.MediaTile]) {
        let blossomDir = ConfigService.shared.relayDataDir
            .appendingPathComponent(ConfigService.shared.config.blossomPath)

        let local: [(id: String, file: URL, kind: NVMediaKind?)] = tiles.compactMap { tile in
            let file = blossomDir.appendingPathComponent(tile.url.lastPathComponent)
            return FileManager.default.fileExists(atPath: file.path) ? (tile.id, file, tile.kind) : nil
        }
        guard !local.isEmpty else { return }

        Task.detached(priority: .utility) {
            var encoded: [(id: String, data: Data)] = []
            for entry in local {
                let data = entry.kind == .video ? videoPoster(entry.file)
                                                : NVDownsample.tile(fileURL: entry.file, maxPixel: 160)
                guard let data else { continue }
                encoded.append((entry.id, data))
            }

            let keep = Set(NVThumbnailBudget.fit(encoded.map { ($0.id, $0.data.count) },
                                                 budget: NVThumbnailStore.budget))
            var images: [String: Data] = [:]
            for entry in encoded where keep.contains(entry.id) { images[entry.id] = entry.data }
            guard !images.isEmpty else { return }

            NVThumbnailStore.save(NVThumbnailBundle(generatedAt: Date(), images: images))
            await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        }
    }

    /// First frame of a local video, shrunk to a tile. ImageIO cannot read a
    /// movie container, so without this every video tile falls back to a tinted
    /// square and the Video filter looks empty even when it is not.
    private nonisolated static func videoPoster(_ file: URL) -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        // Half a second in: frame zero is black on a lot of footage.
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.55] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// A note counts as a mention when it p-tags you and is not your own.
    private static func mentions(_ me: String, _ note: FeedNote) -> Bool {
        guard !me.isEmpty, note.pubkey != me else { return false }
        return note.tags.contains { $0.count >= 2 && $0[0] == "p" && $0[1] == me }
    }

    private static func note(_ n: FeedNote, nostr: NostrService) -> NVWidgetSnapshot.Note {
        let profile = nostr.profiles[n.pubkey]
        return .init(
            id: n.id,
            authorName: profile?.bestName ?? ("npub…" + String(n.pubkey.suffix(6))),
            authorPictureURL: profile?.pictureURL,
            // Widgets have no link or media rendering, so collapse whitespace
            // and hand over plain text rather than something half-parsed.
            text: n.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: n.createdAt,
            imageURL: n.mediaURLs.first
        )
    }

}

// MARK: - Deep links

@MainActor
enum NVDeepLinkRouter {
    /// Routes a `nostrvault://` URL onto the same notifications the push
    /// handler already uses, so widget taps and notification taps land the
    /// same way instead of growing a second navigation path.
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard let link = NVDeepLink(url: url) else { return false }
        let center = NotificationCenter.default

        switch link {
        case .feed:
            center.post(name: .havenOpenFeed, object: nil)
        case .mentions:
            center.post(name: .havenOpenMentions, object: nil)
        case .compose:
            center.post(name: .havenOpenFeed, object: nil)
            center.post(name: .composeFromTabBar, object: 0)
        case .dms:
            DMService.shared.refresh()
            center.post(name: .havenOpenDMInbox, object: nil)
        case .search:
            center.post(name: .havenOpenSearch, object: nil)
        case .relay:
            center.post(name: .havenOpenViewer, object: nil)
        case .media:
            center.post(name: .havenOpenMedia, object: nil)
        case .mediaPaste:
            center.post(name: .havenOpenMedia, object: nil)
            // A beat behind the tab switch: the gallery has to be on screen and
            // listening before the paste fires, or the tap does nothing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                center.post(name: .havenMagicPaste, object: nil)
            }
        case .wallet:
            center.post(name: .havenOpenWallet, object: nil)
        }
        return true
    }
}
