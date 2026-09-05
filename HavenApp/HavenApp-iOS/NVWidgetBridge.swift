import Foundation
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
            // Mosaic is fed from media attached to your own recent notes. The
            // app has no published list of Blossom blobs to read; when one
            // exists this should switch to it, since "my media" and "media in
            // my last 40 notes" are not the same set.
            media: recent
                .filter { $0.pubkey == me }
                .flatMap { n in n.mediaURLs.map { NVWidgetSnapshot.MediaTile(id: n.id + $0.absoluteString, url: $0) } }
                .prefix(18)
                .map { $0 },
            unreadDMCount: DMService.shared.totalUnreadCount,
            eventsPerHour: hourlyBuckets(recent)
        )
    }

    private static let processStart = Date()

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

    /// 24 hourly counts of what the feed is holding, oldest first.
    ///
    /// This is feed volume, not relay ingest -- the relay's own per-hour
    /// history is not exposed to the app. It is honest as "how busy has your
    /// feed been", which is what the sparkline is read as anyway.
    private static func hourlyBuckets(_ notes: [FeedNote]) -> [Int] {
        var buckets = [Int](repeating: 0, count: 24)
        let now = Date()
        for n in notes {
            let hoursAgo = Int(now.timeIntervalSince(n.createdAt) / 3_600)
            guard hoursAgo >= 0, hoursAgo < 24 else { continue }
            buckets[23 - hoursAgo] += 1
        }
        return buckets
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
        case .wallet:
            center.post(name: .havenOpenWallet, object: nil)
        }
        return true
    }
}
