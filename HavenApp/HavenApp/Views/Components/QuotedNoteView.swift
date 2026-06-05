import SwiftUI

struct QuotedNoteView: View {
    let note: FeedNote
    @EnvironmentObject var nostrService: NostrService
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                let profile = nostrService.profiles[note.pubkey]
                AvatarView(url: profile?.pictureURL, pubkey: note.pubkey, size: 18)
                
                Text(profile?.bestName ?? "Someone")
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.9))

                Spacer()

                Text(relativeTime(note.createdAt))
                    .font(.appSystem(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.7))
            }

            let formattedContent = NostrContentFormatter.format(note.content, mediaURLs: note.mediaURLs, hideQuotes: true)
            if !formattedContent.characters.isEmpty {
                Text(formattedContent)
                    .font(.appSystem(size: 13, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            
            if !note.mediaURLs.isEmpty {
                FeedMediaView(
                    url: note.mediaURLs[0],
                    maxHeight: 180,
                    portraitMaxHeight: 220,
                    isThumbnail: false
                )
                .allowsHitTesting(false)
            }
        }
        .padding(10)
        .background(Color.platformTertiaryGroupedBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    Color.havenPurple.opacity(ConfigService.shared.config.useOLED ? 0.30 : 0.12),
                    lineWidth: ConfigService.shared.config.useOLED ? 1.2 : 0.5
                )
        )
    }
    
    private func relativeTime(_ date: Date) -> String {
        let diff = Date().timeIntervalSince(date)
        switch diff {
        case ..<60:         return "now"
        case ..<3600:       return "\(Int(diff / 60))m"
        case ..<86400:      return "\(Int(diff / 3600))h"
        case ..<604800:     return "\(Int(diff / 86400))d"
        default:
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d"
            return fmt.string(from: date)
        }
    }
}
