import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Mosaic
//
// Your Blossom media as a grid. The only widget here that is decorative rather
// than informational, and the one that most rewards an iPad's extraLarge slot.

enum MosaicStyle: String, AppEnum {
    case grid, featured

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Layout" }
    static var caseDisplayRepresentations: [MosaicStyle: DisplayRepresentation] = [
        .grid: "Even grid",
        .featured: "One large, rest small",
    ]
}

struct MosaicIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Mosaic"
    static var description = IntentDescription("Your Blossom media, live on the Home Screen.")

    @Parameter(title: "Layout", default: .grid)
    var style: MosaicStyle

    @Parameter(title: "Rounded tiles", default: true)
    var rounded: Bool
}

struct MosaicEntry: TimelineEntry {
    let date: Date
    let snapshot: NVWidgetSnapshot
    let config: MosaicIntent
}

struct MosaicProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MosaicEntry {
        MosaicEntry(date: Date(), snapshot: .preview, config: MosaicIntent())
    }

    func snapshot(for configuration: MosaicIntent, in context: Context) async -> MosaicEntry {
        MosaicEntry(date: Date(), snapshot: NVSharedStore.load() ?? .preview, config: configuration)
    }

    func timeline(for configuration: MosaicIntent, in context: Context) async -> Timeline<MosaicEntry> {
        let entry = MosaicEntry(date: Date(), snapshot: NVSharedStore.load() ?? .empty, config: configuration)
        // Media changes less often than relay counters, and every entry costs a
        // batch of image fetches, so this one refreshes on the hour.
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 60)))
    }
}

struct MosaicView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MosaicEntry

    private var tiles: [NVWidgetSnapshot.MediaTile] {
        Array(entry.snapshot.media.prefix(capacity))
    }

    /// Tile counts sized so each cell stays large enough to read as an image
    /// rather than a swatch.
    private var capacity: Int {
        switch family {
        case .systemSmall: return entry.config.style == .featured ? 1 : 4
        case .systemMedium: return entry.config.style == .featured ? 5 : 8
        case .systemLarge: return entry.config.style == .featured ? 7 : 12
        case .systemExtraLarge: return entry.config.style == .featured ? 9 : 18
        default: return 4
        }
    }

    private var columns: Int {
        switch family {
        case .systemSmall: return 2
        case .systemMedium: return 4
        case .systemLarge: return 3
        case .systemExtraLarge: return 6
        default: return 2
        }
    }

    private var corner: CGFloat { entry.config.rounded ? 8 : 0 }

    var body: some View {
        if tiles.isEmpty {
            NVEmptyState(icon: "photo.on.rectangle",
                         message: entry.snapshot.hasEverRun ? "No media on your relay yet"
                                                            : "Open Nostr Vault to load your media")
        } else if entry.config.style == .featured, let hero = tiles.first {
            VStack(spacing: 4) {
                Tile(url: hero.url, corner: corner)
                    .frame(maxWidth: .infinity)
                if tiles.count > 1 {
                    HStack(spacing: 4) {
                        ForEach(tiles.dropFirst()) { tile in
                            Tile(url: tile.url, corner: corner)
                        }
                    }
                    .frame(height: family == .systemSmall ? 0 : 44)
                }
            }
            .widgetURL(NVDeepLink.media.url)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
                ForEach(tiles) { tile in
                    Tile(url: tile.url, corner: corner)
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            .widgetURL(NVDeepLink.media.url)
        }
    }
}

private struct Tile: View {
    let url: URL
    let corner: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(Color.white.opacity(0.07))
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

struct MosaicWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "Mosaic", intent: MosaicIntent.self, provider: MosaicProvider()) { entry in
            MosaicView(entry: entry)
                .containerBackground(NV.background, for: .widget)
        }
        .configurationDisplayName("Mosaic")
        .description("Your Blossom media as a living grid.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}
