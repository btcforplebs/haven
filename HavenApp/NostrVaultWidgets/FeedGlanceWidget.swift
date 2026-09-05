import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Feed Glance
//
// Recent notes. The point of this one on iPad is that extraLarge finally has
// room to be a real reading surface rather than a teaser.

enum FeedSource: String, AppEnum {
    case following, mentions

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Source" }
    static var caseDisplayRepresentations: [FeedSource: DisplayRepresentation] = [
        .following: "Following",
        .mentions: "Mentions",
    ]
}

enum FeedDensity: String, AppEnum {
    case comfortable, compact

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Density" }
    static var caseDisplayRepresentations: [FeedDensity: DisplayRepresentation] = [
        .comfortable: "Comfortable",
        .compact: "Compact",
    ]
}

struct FeedGlanceIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Feed Glance"
    static var description = IntentDescription("Recent notes from your feed or your mentions.")

    @Parameter(title: "Source", default: .following)
    var source: FeedSource

    @Parameter(title: "Density", default: .comfortable)
    var density: FeedDensity

    @Parameter(title: "Show avatars", default: true)
    var showAvatars: Bool
}

struct FeedGlanceEntry: TimelineEntry {
    let date: Date
    let snapshot: NVWidgetSnapshot
    let config: FeedGlanceIntent
}

struct FeedGlanceProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> FeedGlanceEntry {
        FeedGlanceEntry(date: Date(), snapshot: .preview, config: FeedGlanceIntent())
    }

    func snapshot(for configuration: FeedGlanceIntent, in context: Context) async -> FeedGlanceEntry {
        FeedGlanceEntry(date: Date(), snapshot: NVSharedStore.load() ?? .preview, config: configuration)
    }

    func timeline(for configuration: FeedGlanceIntent, in context: Context) async -> Timeline<FeedGlanceEntry> {
        let entry = FeedGlanceEntry(date: Date(), snapshot: NVSharedStore.load() ?? .empty, config: configuration)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60)))
    }
}

struct FeedGlanceView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FeedGlanceEntry

    private var notes: [NVWidgetSnapshot.Note] {
        let all = entry.config.source == .mentions ? entry.snapshot.mentions : entry.snapshot.feed
        return Array(all.prefix(rowCount))
    }

    /// Row budget per family, halved-ish for compact density. These are tuned to
    /// fill the box without the last row being clipped -- a clipped final row is
    /// the single most common way a feed widget looks broken.
    private var rowCount: Int {
        let base: Int
        switch family {
        case .systemMedium: base = 2
        case .systemLarge: base = 5
        case .systemExtraLarge: base = 6
        default: base = 1
        }
        return entry.config.density == .compact ? base + (base >= 5 ? 3 : 1) : base
    }

    private var deepLink: URL {
        entry.config.source == .mentions ? NVDeepLink.mentions.url : NVDeepLink.feed.url
    }

    var body: some View {
        if !entry.snapshot.hasEverRun {
            NVEmptyState(icon: "person.2.wave.2", message: "Open Nostr Vault to load your feed")
        } else if notes.isEmpty {
            NVEmptyState(icon: entry.config.source == .mentions ? "at" : "person.2.wave.2",
                         message: entry.config.source == .mentions ? "No recent mentions" : "No recent notes")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 5)
                VStack(alignment: .leading, spacing: entry.config.density == .compact ? 6 : 10) {
                    ForEach(notes) { note in
                        NoteRow(note: note,
                                showAvatar: entry.config.showAvatars,
                                compact: entry.config.density == .compact)
                    }
                }
                Spacer(minLength: 0)
            }
            .widgetURL(deepLink)
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: entry.config.source == .mentions ? "at" : "person.2.wave.2")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NV.purple)
            Text(entry.config.source == .mentions ? "Mentions" : "Following")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if entry.snapshot.isStale {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct NoteRow: View {
    let note: NVWidgetSnapshot.Note
    let showAvatar: Bool
    let compact: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            if showAvatar {
                Avatar(url: note.authorPictureURL, seed: note.id)
                    .frame(width: compact ? 16 : 22, height: compact ? 16 : 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(note.authorName)
                        .font(.system(size: compact ? 10 : 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(NV.shortAge(note.createdAt))
                        .font(.system(size: compact ? 9 : 10))
                        .foregroundStyle(.secondary)
                }
                Text(note.text)
                    .font(.system(size: compact ? 10 : 12))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(compact ? 1 : 2)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Avatars are fetched by the widget rather than shipped in the snapshot -- a
/// keychain item is the wrong place for image bytes. When there is no picture,
/// the pubkey-derived hue keeps rows visually distinct instead of a row of
/// identical grey circles.
private struct Avatar: View {
    let url: URL?
    let seed: String

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .clipShape(Circle())
    }

    private var fallback: some View {
        Circle().fill(
            LinearGradient(colors: [hue.opacity(0.9), hue.opacity(0.45)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private var hue: Color {
        Color(hue: Double(abs(seed.hashValue) % 360) / 360, saturation: 0.55, brightness: 0.85)
    }
}

struct FeedGlanceWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "FeedGlance", intent: FeedGlanceIntent.self, provider: FeedGlanceProvider()) { entry in
            FeedGlanceView(entry: entry)
                .containerBackground(NV.background, for: .widget)
        }
        .configurationDisplayName("Feed Glance")
        .description("Recent notes from your feed or mentions.")
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
    }
}
