import SwiftUI

/// GIF keyboard backed by getyarn.io: type a quote, get a grid of movie/TV
/// clips, tap one to hand it back to the caller as a `YarnClip`.
struct YarnGifPickerSheet: View {
    var onSelect: (YarnClip) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [YarnClip] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var selectingUUID: String?
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                Divider()
                content
            }
            .navigationTitle("GIFs")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 420, idealHeight: 560)
        #endif
        .onAppear { searchFocused = true }
        .onDisappear { searchTask?.cancel() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search a quote, e.g. \"that's what she said\"", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { runSearch(immediate: true) }
                .onChange(of: query) { _, _ in runSearch(immediate: false) }
            if isSearching {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            placeholder(icon: "exclamationmark.triangle", text: errorMessage)
        } else if results.isEmpty {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                placeholder(icon: "film", text: "Search movie and TV quotes from getyarn.io")
            } else if !isSearching {
                placeholder(icon: "magnifyingglass", text: "No clips found for \u{201C}\(query)\u{201D}")
            } else {
                Spacer()
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(results) { clip in
                        YarnClipCell(clip: clip, isSelecting: selectingUUID == clip.uuid)
                            .onTapGesture { select(clip) }
                    }
                }
                .padding(12)
                Text("Clips from getyarn.io")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 12)
            }
        }
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text(text)
                .font(.appSystem(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func runSearch(immediate: Bool) {
        searchTask?.cancel()
        errorMessage = nil
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = []
            isSearching = false
            return
        }
        searchTask = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { isSearching = true }
            do {
                let clips = try await YarnClipService.search(text)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    results = clips
                    isSearching = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSearching = false
                }
            }
        }
    }

    private func select(_ clip: YarnClip) {
        guard selectingUUID == nil else { return }
        selectingUUID = clip.uuid
        onSelect(clip)
        dismiss()
    }
}

private struct YarnClipCell: View {
    let clip: YarnClip
    let isSelecting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Color.platformSecondaryGroupedBackground
                AnimatedImage(url: clip.gifSmallURL, contentMode: .fill, fallbackURL: clip.thumbURL)
                if isSelecting {
                    Color.black.opacity(0.4)
                    ProgressView().tint(.white)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(clip.transcript)
                .font(.appSystem(size: 12, weight: .medium))
                .lineLimit(2)
            Text(clip.videoTitle)
                .font(.appSystem(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .help(clip.transcript)
    }
}
