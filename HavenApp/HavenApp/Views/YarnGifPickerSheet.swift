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
    /// Next getyarn page to request. 0-based, incremented once a page lands.
    @State private var nextPage = 0
    /// getyarn returned a short page, so there is nothing further to ask for.
    @State private var reachedEnd = false
    /// How many of `results` the grid is currently showing. Every revealed cell
    /// pulls its own preview GIF from y.yarn.co, so this is the real bandwidth
    /// dial -- a page of 20 costs one HTML request but twenty ~84 KB GIFs.
    @State private var revealed = 0

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8)]
    /// Cells revealed per step. Deliberately smaller than getyarn's page of 20.
    private let revealStep = 8
    /// Hard ceiling on pages requested per search. getyarn gives no end signal
    /// -- p=99 still answers with a full page of 20 -- so without a cap "show
    /// more" would happily walk a free service forever.
    private let maxPages = 5

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                searchField
                content
            }
            .background(Color.platformSecondaryGroupedBackground)
            #if os(iOS)
            .navigationBarHidden(true)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 420, idealHeight: 560)
        #endif
        .onAppear { searchFocused = true }
        .onDisappear { searchTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "film.fill")
                .font(.appSystem(size: 16, weight: .bold))
                .foregroundColor(.havenPurple)

            Text("GIFs")
                .font(.appSystem(size: 18, weight: .bold, design: .rounded))

            Spacer()

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.appSystem(size: 22))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(searchFocused ? .havenPurple : .secondary)
            // Submit only. getyarn.io is a free service with no public API, and
            // an as-you-type search spent a page request plus a fresh grid of
            // preview GIFs on every pause in typing.
            TextField("Search a quote, then press return", text: $query)
                .textFieldStyle(.plain)
                .font(.appSystem(size: 15))
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { runSearch() }
                .onChange(of: query) { _, _ in
                    // Only clear stale results; never fetch.
                    searchTask?.cancel()
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        resetResults()
                    }
                }
            if isSearching {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    query = ""
                    resetResults()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.platformTertiaryGroupedBackground)
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(searchFocused ? Color.havenPurple.opacity(0.6) : Color.platformSeparator, lineWidth: searchFocused ? 1.5 : 0.8)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .animation(.easeOut(duration: 0.15), value: searchFocused)
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            placeholder(icon: "exclamationmark.triangle", text: errorMessage)
                .frame(maxHeight: .infinity)
        } else if results.isEmpty {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                placeholder(icon: "quote.bubble", text: "Search a movie or TV quote to find a clip")
                    .frame(maxHeight: .infinity)
            } else if !isSearching {
                placeholder(icon: "film", text: "No clips found for \u{201C}\(query)\u{201D}")
                    .frame(maxHeight: .infinity)
            } else {
                Spacer()
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(results.prefix(revealed)) { clip in
                        YarnClipCell(clip: clip, isSelecting: selectingUUID == clip.uuid)
                            .onTapGesture { select(clip) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.havenPurple)
                        .padding(.top, 16)
                        .padding(.bottom, 12)
                } else if canShowMore {
                    Button {
                        showMore()
                    } label: {
                        HStack(spacing: 6) {
                            Text("Show more clips")
                            Image(systemName: "chevron.down")
                        }
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Color.havenPurple)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                }

                Text("Clips from getyarn.io")
                    .font(.appCaption2)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 14)
            }
        }
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: icon)
                .font(.appSystem(size: 40, weight: .thin))
                .foregroundColor(.havenPurple.opacity(0.6))
            Text(text)
                .font(.appSystem(size: 14, weight: .medium))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// More to show without asking getyarn for anything, or another page to ask for.
    private var canShowMore: Bool {
        revealed < results.count || (!reachedEnd && nextPage < maxPages)
    }

    private func resetResults() {
        results = []
        revealed = 0
        nextPage = 0
        reachedEnd = false
        errorMessage = nil
        isSearching = false
    }

    /// Starts a new search from page 0. Only ever called from the return key.
    private func runSearch() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            resetResults()
            return
        }
        resetResults()
        fetchNextPage(for: text)
    }

    /// Reveals already-fetched clips first, and only asks getyarn for another
    /// page once the current one is fully on screen.
    private func showMore() {
        if revealed < results.count {
            revealed = min(revealed + revealStep, results.count)
            return
        }
        guard !reachedEnd, !isSearching, nextPage < maxPages else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        fetchNextPage(for: text)
    }

    private func fetchNextPage(for text: String) {
        let page = nextPage
        errorMessage = nil
        isSearching = true
        searchTask = Task {
            do {
                let clips = try await YarnClipService.search(text, page: page)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    // getyarn never signals the end and does not return a
                    // stable ordering for a repeated query, so a later page can
                    // hand back clips we already hold. Dedupe, and treat an
                    // all-duplicate page as the end.
                    let known = Set(results.map(\.uuid))
                    let fresh = clips.filter { !known.contains($0.uuid) }
                    results.append(contentsOf: fresh)
                    reachedEnd = fresh.isEmpty
                    nextPage = page + 1
                    revealed = min(revealed + revealStep, results.count)
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
        ZStack(alignment: .bottomLeading) {
            Color.platformTertiaryGroupedBackground
            AnimatedImage(url: clip.gifSmallURL, contentMode: .fill, fallbackURL: clip.thumbURL)

            // Ambient darkening across the lower half. Softened from 0.75
            // because the caption now carries its own scrim; stacking both at
            // full strength turned the bottom of every cell into a black bar.
            LinearGradient(
                colors: [.clear, .clear, .black.opacity(0.35)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(clip.transcript)
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                Text(clip.videoTitle)
                    .font(.appSystem(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.82))
                    .lineLimit(1)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Scrim sized to the caption rather than to the cell. A fraction of
            // the cell height cannot work here: the grid is adaptive, so a cell
            // is 84-107pt tall while the caption is a fixed ~45pt, and on the
            // short end the first line of the transcript lands above any
            // proportional ramp. Anchoring to the caption keeps white-on-bright
            // legible at every cell width.
            .background(alignment: .bottom) {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0), location: 0),
                        .init(color: .black.opacity(0.70), location: 0.30),
                        .init(color: .black.opacity(0.90), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                // Grow upward so the ramp finishes before the text starts
                // instead of fading across the first line.
                .padding(.top, -18)
                .allowsHitTesting(false)
            }

            if isSelecting {
                Color.black.opacity(0.55)
                ProgressView().tint(.white)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.platformSeparator, lineWidth: 0.8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .help(clip.transcript)
        // The transcript is clamped to two lines and the title to one, so the
        // rendered text is not the whole caption. Read the full strings out.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(clip.transcript), from \(clip.videoTitle)"))
        .accessibilityAddTraits(.isButton)
    }
}
