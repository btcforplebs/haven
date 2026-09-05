import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Vault Pulse
//
// Relay health at a glance: one headline number the user picks, a ring for
// running state, and 24h of event volume as a sparkline.

enum PulseMetric: String, AppEnum {
    case events, storage, connections, uptime

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Headline" }
    static var caseDisplayRepresentations: [PulseMetric: DisplayRepresentation] = [
        .events: "Events stored",
        .storage: "Storage used",
        .connections: "Live connections",
        .uptime: "Uptime",
    ]
}

struct VaultPulseIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Vault Pulse"
    static var description = IntentDescription("Relay health, with the number you care about front and centre.")

    @Parameter(title: "Headline", default: .events)
    var metric: PulseMetric

    @Parameter(title: "Show 24h activity", default: true)
    var showSparkline: Bool
}

struct VaultPulseEntry: TimelineEntry {
    let date: Date
    let snapshot: NVWidgetSnapshot
    let config: VaultPulseIntent
}

struct VaultPulseProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> VaultPulseEntry {
        VaultPulseEntry(date: Date(), snapshot: .preview, config: VaultPulseIntent())
    }

    func snapshot(for configuration: VaultPulseIntent, in context: Context) async -> VaultPulseEntry {
        VaultPulseEntry(date: Date(), snapshot: NVSharedStore.load() ?? .preview, config: configuration)
    }

    func timeline(for configuration: VaultPulseIntent, in context: Context) async -> Timeline<VaultPulseEntry> {
        let entry = VaultPulseEntry(date: Date(), snapshot: NVSharedStore.load() ?? .empty, config: configuration)
        // The app refreshes the snapshot as it runs; the widget only needs to
        // re-read it. 15 minutes keeps us well inside WidgetKit's daily budget
        // while still feeling live.
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60)))
    }
}

struct VaultPulseView: View {
    @Environment(\.widgetFamily) private var family
    let entry: VaultPulseEntry

    private var relay: NVWidgetSnapshot.Relay { entry.snapshot.relay }

    private var headline: String {
        switch entry.config.metric {
        case .events: return NV.compactCount(relay.eventCount)
        case .storage: return NV.compactBytes(relay.storageBytes)
        case .connections: return "\(relay.connectionCount)"
        case .uptime: return uptimeText
        }
    }

    private var caption: String {
        switch entry.config.metric {
        case .events: return "events"
        case .storage: return "stored"
        case .connections: return relay.connectionCount == 1 ? "connection" : "connections"
        case .uptime: return "uptime"
        }
    }

    private var uptimeText: String {
        let s = relay.uptimeSeconds
        if s >= 86_400 { return "\(s / 86_400)d" }
        if s >= 3_600 { return "\(s / 3_600)h" }
        return "\(s / 60)m"
    }

    var body: some View {
        if !entry.snapshot.hasEverRun {
            NVEmptyState(icon: "externaldrive.badge.xmark", message: "Open Nostr Vault to start your relay")
        } else {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    statusRow
                    Spacer(minLength: 4)
                    Text(headline)
                        .font(.system(size: family == .systemSmall ? 30 : 36, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(caption)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    if entry.config.showSparkline {
                        Sparkline(values: entry.snapshot.eventsPerHour)
                            .frame(height: family == .systemSmall ? 22 : 30)
                            .padding(.top, 6)
                    }
                }
                if family != .systemSmall {
                    Spacer(minLength: 12)
                    secondaryColumn
                }
            }
            .widgetURL(NVDeepLink.relay.url)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(relay.isRunning ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
                .shadow(color: (relay.isRunning ? Color.green : Color.orange).opacity(0.8), radius: 3)
            Text(relay.isRunning ? "Relay live" : "Relay stopped")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if entry.snapshot.isStale {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Medium has room to show the metrics the headline did not take.
    private var secondaryColumn: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(Array(others.enumerated()), id: \.offset) { _, pair in
                VStack(alignment: .trailing, spacing: 1) {
                    Text(pair.1)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(pair.0)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var others: [(String, String)] {
        var all: [(PulseMetric, String, String)] = [
            (.events, "events", NV.compactCount(relay.eventCount)),
            (.storage, "stored", NV.compactBytes(relay.storageBytes)),
            (.connections, "peers", "\(relay.connectionCount)"),
            (.uptime, "uptime", uptimeText),
        ]
        all.removeAll { $0.0 == entry.config.metric }
        return all.prefix(3).map { ($0.1, $0.2) }
    }
}

/// 24 hourly buckets as a filled line. Deliberately axis-free and label-free:
/// at widget size the shape is the whole message.
struct Sparkline: View {
    let values: [Int]

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            if pts.count > 1 {
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [NV.purple.opacity(0.45), NV.purple.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: pts[0])
                        pts.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(NV.purple, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        // A flat series must not render as a line pinned to the top of the box,
        // so the range floor is 1 rather than the observed max.
        let hi = CGFloat(max(values.max() ?? 1, 1))
        let stepX = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) * stepX, y: size.height - (CGFloat(v) / hi) * size.height)
        }
    }
}

struct VaultPulseWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "VaultPulse", intent: VaultPulseIntent.self, provider: VaultPulseProvider()) { entry in
            VaultPulseView(entry: entry)
                .containerBackground(NV.background, for: .widget)
        }
        .configurationDisplayName("Vault Pulse")
        .description("Relay health, event volume and uptime.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
