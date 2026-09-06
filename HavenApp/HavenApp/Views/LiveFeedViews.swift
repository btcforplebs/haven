import SwiftUI

/// One tile in the Live grid: thumbnail, a LIVE pill, and the viewer count when
/// the host publishes one.
struct LiveStreamCardView: View {
    let stream: LiveStream
    let profile: FeedProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let imageURL = stream.imageURL {
                        RetryableAsyncImage(url: imageURL, contentMode: .fill, targetSize: CGSize(width: 600, height: 340))
                    } else {
                        // Half the live streams publish no image, so this is the
                        // common case, not a fallback.
                        ZStack {
                            Rectangle().fill(Color.havenPurplePale)
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.appSystem(size: 28))
                                .foregroundColor(.havenPurple.opacity(0.7))
                        }
                    }
                }
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .clipped()

                HStack(spacing: 6) {
                    livePill
                    if let participants = stream.participants {
                        Label("\(participants)", systemImage: "person.2.fill")
                            .font(.appSystem(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.55))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                }
                .padding(8)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(stream.title ?? "Untitled stream")
                    .font(.appSystem(size: 14, weight: .bold))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(profile?.bestName ?? "npub…" + String(stream.hostPubkey.suffix(6)))
                    .font(.appSystem(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(10)
        }
        .background(Color.controlBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.platformSeparator, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }

    private var livePill: some View {
        HStack(spacing: 4) {
            Circle().fill(Color.red).frame(width: 6, height: 6)
            Text("LIVE").font(.appSystem(size: 10, weight: .bold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.55))
        .foregroundColor(.white)
        .clipShape(Capsule())
    }
}

/// Player for one live stream, with the report and block affordances Apple's
/// UGC rules require on any surface showing third-party video.
struct LiveStreamPlayerView: View {
    let stream: LiveStream
    var onBlocked: ((String) -> Void)? = nil

    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @Environment(\.dismiss) private var dismiss
    @State private var showingReportDialog = false
    @State private var showingBlockConfirm = false

    private var profile: FeedProfile? { nostrService.profiles[stream.hostPubkey] }

    var body: some View {
        VStack(spacing: 0) {
            if let url = stream.streamingURL {
                VideoPlayerView(url: url)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(stream.title ?? "Untitled stream")
                        .font(.appSystem(size: 20, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        AvatarView(url: profile?.pictureURL, pubkey: stream.hostPubkey, size: 28)
                        Text(profile?.bestName ?? "npub…" + String(stream.hostPubkey.suffix(6)))
                            .font(.appSystem(size: 13, weight: .semibold))
                        if let participants = stream.participants {
                            Text("· \(participants) watching")
                                .font(.appSystem(size: 12))
                                .foregroundColor(.secondary)
                        }
                        Spacer(minLength: 0)
                    }

                    if let summary = stream.summary {
                        Text(summary)
                            .font(.appSystem(size: 14))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    HStack(spacing: 16) {
                        Button {
                            showingReportDialog = true
                        } label: {
                            Label("Report", systemImage: "flag")
                        }
                        Button(role: .destructive) {
                            showingBlockConfirm = true
                        } label: {
                            Label("Block host", systemImage: "hand.raised")
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.appSystem(size: 13, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundColor(.havenPurple)
                }
                .padding(20)
            }
        }
        .background(Color.platformWindowBackground)
        .sheet(isPresented: $showingReportDialog) {
            // Reporting also blocks, which is what the existing dialog does
            // everywhere else in the app — so the stream must leave the grid.
            UGCReportingDialog(eventId: nil, pubkey: stream.hostPubkey, onDismiss: { showingReportDialog = false }) {
                showingReportDialog = false
                onBlocked?(stream.hostPubkey)
                dismiss()
            }
            .environmentObject(nostrService)
            .environmentObject(configService)
        }
        .alert("Block this host?", isPresented: $showingBlockConfirm) {
            Button("Block", role: .destructive) {
                blockHost()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their streams and posts stop appearing for you.")
        }
    }

    /// The block list is stored as npubs and read back through a bech32 decode,
    /// so handing `blockProfile` a hex pubkey stores an entry that never
    /// matches anything. Convert first, exactly as the note row does.
    private func blockHost() {
        guard let data = Bech32.hexToData(stream.hostPubkey),
              let npub = Bech32.encode(hrp: "npub", data: data) else { return }
        configService.blockProfile(npub)
        nostrService.objectWillChange.send()
        onBlocked?(stream.hostPubkey)
        dismiss()
    }
}
