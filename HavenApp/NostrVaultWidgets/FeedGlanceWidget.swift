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
        entry.config.source == .mentions ? entry.snapshot.mentions : entry.snapshot.feed
    }

    /// One size for everything in this widget -- author, age, body and header.
    /// Mixing three sizes in a box this small reads as clutter rather than
    /// hierarchy; weight and colour carry the hierarchy instead.
    private static let textSize: CGFloat = 12
    private static let lineHeight: CGFloat = 15

    private var bodyLines: Int { entry.config.density == .compact ? 1 : 2 }

    /// A row is the author line plus the body lines. Measured from the one text
    /// size above rather than guessed per family, so the fill maths below stays
    /// true if the size ever changes.
    private var rowHeight: CGFloat {
        Self.lineHeight * CGFloat(1 + bodyLines)
    }

    /// Header, its divider, and the padding around them.
    private static let headerHeight: CGFloat = 26

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
            // The row count comes from the measured height rather than a table
            // of per-family constants: the families are not the only variable
            // (density and the accessibility text size move the row height too),
            // and a fixed count either clips the last row or leaves a hole under
            // it. See NVFeedLayout, which is unit-tested.
            GeometryReader { geo in
                let plan = NVFeedLayout.plan(availableHeight: geo.size.height,
                                             headerHeight: Self.headerHeight,
                                             rowHeight: rowHeight,
                                             minSpacing: 6,
                                             maxSpacing: 18,
                                             noteCount: notes.count)
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 5)
                    VStack(alignment: .leading, spacing: plan.spacing) {
                        ForEach(notes.prefix(plan.rows)) { note in
                            NoteRow(note: note,
                                    showAvatar: entry.config.showAvatars,
                                    size: Self.textSize,
                                    bodyLines: bodyLines)
                        }
                    }
                }
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
                .font(.system(size: Self.textSize, weight: .semibold))
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
    /// One size for the whole row. Name, age and body differ by weight and
    /// colour only -- see FeedGlanceView.textSize.
    let size: CGFloat
    let bodyLines: Int

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            if showAvatar {
                Avatar(url: note.authorPictureURL, seed: note.id)
                    .frame(width: size + 8, height: size + 8)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(note.authorName)
                        .font(.system(size: size, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(NV.shortAge(note.createdAt))
                        .font(.system(size: size))
                        .foregroundStyle(.secondary)
                }
                Text(note.text)
                    .font(.system(size: size))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(bodyLines)
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
