import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Sats
//
// Wallet balance and zap flow. This is the one widget whose contents are
// nobody else's business, so it ships with a blur toggle -- a balance on a
// Home Screen is readable by anyone glancing over a shoulder.

enum SatsDisplay: String, AppEnum {
    case total, cashu, lightning, zaps

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Headline" }
    static var caseDisplayRepresentations: [SatsDisplay: DisplayRepresentation] = [
        .total: "Total balance",
        .cashu: "Cashu balance",
        .lightning: "Lightning balance",
        .zaps: "Zaps today",
    ]
}

struct SatsIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Sats"
    static var description = IntentDescription("Balance, zaps and price.")

    @Parameter(title: "Headline", default: .total)
    var display: SatsDisplay

    @Parameter(title: "Hide amounts", default: false)
    var privacyBlur: Bool

    @Parameter(title: "Show BTC price", default: true)
    var showPrice: Bool
}

struct SatsEntry: TimelineEntry {
    let date: Date
    let snapshot: NVWidgetSnapshot
    let config: SatsIntent
}

struct SatsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SatsEntry {
        SatsEntry(date: Date(), snapshot: .preview, config: SatsIntent())
    }

    func snapshot(for configuration: SatsIntent, in context: Context) async -> SatsEntry {
        SatsEntry(date: Date(), snapshot: NVSharedStore.load() ?? .preview, config: configuration)
    }

    func timeline(for configuration: SatsIntent, in context: Context) async -> Timeline<SatsEntry> {
        let entry = SatsEntry(date: Date(), snapshot: NVSharedStore.load() ?? .empty, config: configuration)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60)))
    }
}

struct SatsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SatsEntry

    private var wallet: NVWidgetSnapshot.Wallet { entry.snapshot.wallet }

    private var amount: Int? {
        switch entry.config.display {
        case .total: return wallet.totalSats
        case .cashu: return wallet.cashuSats
        case .lightning: return wallet.lightningSats
        case .zaps: return wallet.zapsReceived24h
        }
    }

    private var caption: String {
        switch entry.config.display {
        case .total: return "sats"
        case .cashu: return "cashu"
        case .lightning: return "lightning"
        case .zaps: return "zaps today"
        }
    }

    var body: some View {
        if !entry.snapshot.hasEverRun {
            NVEmptyState(icon: "bolt.slash", message: "Open Nostr Vault to see your wallet")
        } else {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(NV.orange)
                        Text("Sats")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    amountView
                    Text(caption)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    if entry.config.showPrice, let price = wallet.btcPriceUSD {
                        Text(priceText(price))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.8))
                            .padding(.top, 4)
                    }
                }
                if family == .systemMedium {
                    Spacer(minLength: 12)
                    zapColumn
                }
            }
            .widgetURL(NVDeepLink.wallet.url)
        }
    }

    @ViewBuilder
    private var amountView: some View {
        let text = amount.map { NV.compactCount($0) } ?? "—"
        Text(text)
            .font(.system(size: family == .systemSmall ? 30 : 36, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            // redacted() rather than a blur: it is the system's own
            // placeholder treatment, so it reads as deliberately hidden
            // instead of as a rendering glitch.
            .redacted(reason: entry.config.privacyBlur ? .placeholder : [])
    }

    private var zapColumn: some View {
        VStack(alignment: .trailing, spacing: 8) {
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(wallet.zapsReceived24h)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(NV.orange)
                Text("zaps 24h")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if let c = wallet.cashuSats, entry.config.display != .cashu {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(NV.compactCount(c))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .redacted(reason: entry.config.privacyBlur ? .placeholder : [])
                    Text("cashu")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func priceText(_ price: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return "BTC $" + (f.string(from: NSNumber(value: price)) ?? "\(Int(price))")
    }
}

struct SatsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "Sats", intent: SatsIntent.self, provider: SatsProvider()) { entry in
            SatsView(entry: entry)
                .containerBackground(NV.background, for: .widget)
        }
        .configurationDisplayName("Sats")
        .description("Wallet balance, zaps received and the BTC price.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
