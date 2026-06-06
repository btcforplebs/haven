import SwiftUI
import AVFoundation
import Combine
import PhotosUI
import UniformTypeIdentifiers
import CryptoKit
#if os(iOS)
import Photos
#endif

struct ViewerView: View {
    let mediaOnly: Bool
    let embedded: Bool

    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var relayManager: RelayProcessManager
    @StateObject private var feedService = FeedService.shared

    @State private var navigationPath = NavigationPath()
    @State private var committedSearch = ""
    @State private var searchScope: SearchScope = .notes
    @State private var displayProfileResults: [FeedProfile] = []
    @State private var viewMode: ViewMode = .notes

    init(mediaOnly: Bool = false, embedded: Bool = false) {
        self.mediaOnly = mediaOnly
        self.embedded = embedded
        if mediaOnly {
            _viewMode = State(initialValue: .media)
        }
    }
    @ObservedObject private var blossomCache = BlossomMediaCache.shared
    @State private var selectedMedia: MediaItem? = nil
    @State private var initialLoad = false
    @State private var isLoadingMore = false
    @State private var contentFilter: ContentFilter = .all
    @State private var mediaSourceFilter: MediaSourceFilter = .all
    @State private var likesFilter: LikesFilter = .onMyNotes
    @State private var zapsFilter: ZapsFilter = .onMyNotes
    @State private var mediaLocationFilter: MediaLocationFilter = .all
    @State private var mediaTypeFilter: Set<MediaTypeFilter> = Set(MediaTypeFilter.allCases)

    // Cached display data (computed in background)
    @State private var displayNotes: [NostrEvent] = []
    @State private var displayMedia: [MediaItem] = []
    @State private var displayLikedNotes: [NostrEvent] = []
    /// Maps note ID -> list of (reactor pubkey, reaction emoji) tuples
    @State private var reactionMap: [String: [(pubkey: String, emoji: String)]] = [:]
    /// Maps note ID -> most recent reaction date
    @State private var latestReactionDates: [String: Date] = [:]
    @State private var displayZappedNotes: [NostrEvent] = []
    /// Maps note ID -> list of (zapper pubkey, amount in sats)
    @State private var zapMap: [String: [(pubkey: String, amount: Int64)]] = [:]
    /// Maps note ID -> list of pubkeys who reposted it
    @State private var repostMap: [String: [String]] = [:]
    /// Maps note ID -> list of pubkeys who quoted it
    @State private var quoteMap: [String: [String]] = [:]

    // Stable loading state so the empty-state message doesn't flash
    // before the display data has been computed at least once per tab.
    @State private var notesHasLoadedOnce: Bool = false
    @State private var mediaHasLoadedOnce: Bool = false
    @State private var likesHasLoadedOnce: Bool = false
    @State private var likesInitialSettled: Bool = false
    @State private var likesSettleTask: Task<Void, Never>?
    @State private var zapsHasLoadedOnce: Bool = false
    @State private var zapsInitialSettled: Bool = false
    @State private var zapsSettleTask: Task<Void, Never>?
    #if os(macOS)
    @State private var keyMonitor: Any? = nil
    #endif

    // Debounce refreshAll() to prevent rapid-fire resubscriptions
    @State private var refreshDebounceTask: Task<Void, Never>?

    // New-event notification highlights for mode buttons
    @State private var hasNewNotes = false
    @State private var hasNewLikes = false
    @State private var hasNewZaps = false
    @State private var notificationBaseline: [Int: Int] = [:] // event kind -> count
    @State private var hasEstablishedNotificationBaseline = false

    @State private var showingNoteId: String?
    @State private var showingProfilePubkey: String?
    @State private var maxDisplayedItems: Int = 50
    #if os(iOS)
    @State private var saveToPhotosMessage: String?
    #endif
    @State private var isCopied = false
    @State private var requestedMissingIds = Set<String>()
    @State private var requestedMissingZapNoteIds = Set<String>()
    /// Cache of parsed zap receipt data keyed by receipt event ID.
    /// Avoids re-parsing JSON description tags on every updateDisplayData cycle.
    @State private var zapReceiptCache: [String: ParsedZapReceipt] = [:]
    
    // Media Uploads
    @State private var selectedUploadItems: [PhotosPickerItem] = []
    @State private var showingFileImporter = false
    @State private var showingPhotoPicker = false
    @State private var showingUploadOptions = false
    @State private var photosPickerFilter: PHPickerFilter = .any(of: [.images, .videos])
    @State private var isPastingContent = false
    @State private var pasteError: String?
    @State private var activeUploadTasks: [Task<Void, Never>] = []
    @State private var showingBlossomMediaList = false
    @State private var mediaLayoutMode: MediaLayoutMode = .grid
    @AppStorage("viewerNoteLayoutMode") private var noteLayoutMode: NoteLayoutMode = .expanded

    enum MediaLayoutMode {
        case grid
        case list
    }

    enum NoteLayoutMode: String {
        case expanded
        case compact
    }

    private var blossomService: BlossomService {
        BlossomService(configService: configService, nostrService: nostrService)
    }


    // Debounce mechanism for updateDisplayData
    @State private var updateTask: Task<Void, Never>?
    @State private var updateGeneration: Int = 0
    @State private var dragOffset: CGSize = .zero
    @State private var showingRelayDashboard = false

    // Static regex pattern to avoid recompilation
    nonisolated private static let hexPattern = try! NSRegularExpression(pattern: "[a-f0-9]{64}", options: .caseInsensitive)
    
    enum ContentFilter {
        case all
        case mine
        case tagged
        case whitelist
    }

    enum ViewMode {
        case notes
        case media
        case likes
        case zaps
    }

    enum LikesFilter {
        case onMyNotes
        case onTagged
        case onWhitelisted
        case myLikes
    }

    enum ZapsFilter {
        case onMyNotes
        case onTagged
        case onWhitelisted
        case myZaps
    }

    struct ParsedZapReceipt {
        let senderPubkey: String
        let targetNoteId: String?
        let amountSats: Int64
    }
    
    enum MediaSourceFilter {
        case all
        case blossom
        case cache
    }

    enum MediaLocationFilter {
        case all
        case blossom
        case cache
        case notFound
    }

    enum MediaTypeFilter: String, CaseIterable {
        case photo = "Photo"
        case video = "Video"
        case gif = "GIF"
        case other = "Other"
    }

    enum SearchScope: CaseIterable, Equatable {
        case notes
        case profiles
        case hashtags

        var label: String {
            switch self {
            case .notes: return "Notes"
            case .profiles: return "Profiles"
            case .hashtags: return "Hashtags"
            }
        }

        var icon: String {
            switch self {
            case .notes: return "doc.text"
            case .profiles: return "person.2"
            case .hashtags: return "number"
            }
        }
    }

    // MARK: - Background Processing
    
    
    private func scheduleUpdateDisplayData() {
        updateTask?.cancel()
        updateGeneration += 1
        let gen = updateGeneration
        updateTask = Task { @MainActor in
            // Debounce: wait 150ms so rapid-fire triggers coalesce into one update
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, gen == updateGeneration else { return }
            updateDisplayData()
        }
    }

    // MARK: - New Event Notification Tracking

    /// Snapshot current event kind counts as the notification baseline.
    /// Called after initial data settles and when the user views a tab.
    private func establishNotificationBaseline() {
        var counts: [Int: Int] = [:]
        for event in nostrService.events {
            counts[event.kind, default: 0] += 1
        }
        notificationBaseline = counts
        hasEstablishedNotificationBaseline = true
    }

    /// Check if new events arrived for categories the user isn't currently viewing.
    private func checkForNewNotifications() {
        guard hasEstablishedNotificationBaseline else { return }

        var counts: [Int: Int] = [:]
        for event in nostrService.events {
            counts[event.kind, default: 0] += 1
        }

        // Notes: kinds 1, 30023
        let noteCount = (counts[1] ?? 0) + (counts[30023] ?? 0)
        let baselineNotes = (notificationBaseline[1] ?? 0) + (notificationBaseline[30023] ?? 0)
        if noteCount > baselineNotes && viewMode != .notes {
            withAnimation(.easeInOut(duration: 0.3)) { hasNewNotes = true }
        }

        // Likes: kind 7
        if (counts[7] ?? 0) > (notificationBaseline[7] ?? 0) && viewMode != .likes {
            withAnimation(.easeInOut(duration: 0.3)) { hasNewLikes = true }
        }

        // Zaps: kind 9735
        if (counts[9735] ?? 0) > (notificationBaseline[9735] ?? 0) && viewMode != .zaps {
            withAnimation(.easeInOut(duration: 0.3)) { hasNewZaps = true }
        }
    }

    /// Clear the notification flag for the given tab and update its baseline.
    private func markTabViewed(_ mode: ViewMode) {
        let events = nostrService.events
        switch mode {
        case .notes:
            if hasNewNotes {
                withAnimation(.easeInOut(duration: 0.2)) { hasNewNotes = false }
            }
            notificationBaseline[1] = events.filter { $0.kind == 1 }.count
            notificationBaseline[30023] = events.filter { $0.kind == 30023 }.count
        case .likes:
            if hasNewLikes {
                withAnimation(.easeInOut(duration: 0.2)) { hasNewLikes = false }
            }
            notificationBaseline[7] = events.filter { $0.kind == 7 }.count
        case .zaps:
            if hasNewZaps {
                withAnimation(.easeInOut(duration: 0.2)) { hasNewZaps = false }
            }
            notificationBaseline[9735] = events.filter { $0.kind == 9735 }.count
        case .media:
            break
        }
    }

    /// Flips `likesInitialSettled` to true once fetching has been quiet for ~1.5s
    /// while in likes mode. Lets the empty state appear without flashing the
    /// spinner on every transient `isFetching` toggle.
    private func updateLikesSettleState() {
        likesSettleTask?.cancel()
        let busy = nostrService.isFetching || relayManager.isBooting
        if busy {
            likesInitialSettled = false
            // Fallback: settle after 5s even if still fetching, so the
            // spinner doesn't stay forever when a relay never sends EOSE.
            likesSettleTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                likesInitialSettled = true
            }
            return
        }
        likesSettleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            if !(nostrService.isFetching || relayManager.isBooting) {
                likesInitialSettled = true
            }
        }
    }

    private func updateZapsSettleState() {
        zapsSettleTask?.cancel()
        let busy = nostrService.isFetching || relayManager.isBooting
        if busy {
            zapsInitialSettled = false
            // Fallback: settle after 5s even if still fetching, so the
            // spinner doesn't stay forever when a relay never sends EOSE.
            zapsSettleTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                zapsInitialSettled = true
            }
            return
        }
        zapsSettleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            if !(nostrService.isFetching || relayManager.isBooting) {
                zapsInitialSettled = true
            }
        }
    }

    private nonisolated static func applySearchFilter(
        to events: [NostrEvent],
        search: String,
        scope: SearchScope
    ) -> [NostrEvent] {
        guard !search.isEmpty else { return events }
        switch scope {
        case .notes:
            return events.filter {
                $0.content.localizedCaseInsensitiveContains(search)
            }
        case .hashtags:
            let normalizedQuery = search
                .lowercased()
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "#", with: "")
            return events.filter { event in
                event.tags.contains { tag in
                    tag.count >= 2
                        && tag[0] == "t"
                        && tag[1].lowercased().contains(normalizedQuery)
                }
            }
        case .profiles:
            return events
        }
    }

    private func updateDisplayData() {
        // Capture current state strongly for the background task
        let currentFilter = contentFilter
        let currentSearch = committedSearch
        let currentScope = searchScope
        let currentEvents = nostrService.events
        let currentNoteMedia = nostrService.noteMedia
        let currentBlossom = blossomCache.items
        let owner = nostrService.activeHexPubkey
        let isOwnerBrowsing = (owner == nostrService.ownerHexPubkey)
        let whitelist = configService.whitelistedHexPubkeys
        let blacklist = configService.activeAccountBlockedHexPubkeys

        #if DEBUG
        print("updateDisplayData: blossom=\(currentBlossom.count) noteMedia=\(currentNoteMedia.count) events=\(currentEvents.count) filter=\(currentFilter) source=\(mediaSourceFilter)")
        #endif
        let currentMode = viewMode
        let currentLocationFilter = mediaLocationFilter
        let currentTypeFilter = mediaTypeFilter
        let currentLikesFilter = likesFilter
        let currentZapsFilter = zapsFilter
        let currentMirrorHosts: Set<String> = Set(
            configService.config.activeBlossomMirrors.compactMap {
                URL(string: $0)?.host?.lowercased()
            }
        )
        let macRelayHttps = configService.config.macRelayHttpsURL
        let currentNotFound = MediaCacheService.shared.known404Set()
        let currentMaxDisplayed = maxDisplayedItems
        let gen = updateGeneration

        Task.detached(priority: .userInitiated) {
            if currentMode == .likes {
                // MARK: - Likes Mode
                let noteKinds = [1, 6, 30023]

                if currentLikesFilter == .myLikes {
                    // My Likes: notes I reacted to (kind 7 from me)
                    var myLikeDates: [String: Date] = [:]
                    for event in currentEvents where event.kind == 7 && event.pubkey == owner {
                        if let targetId = event.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] {
                            if let existing = myLikeDates[targetId] {
                                if event.createdAtDate > existing { myLikeDates[targetId] = event.createdAtDate }
                            } else {
                                myLikeDates[targetId] = event.createdAtDate
                            }
                        }
                    }
                    let myLikedNoteIds = Set(myLikeDates.keys)
                    var filtered = currentEvents.filter { noteKinds.contains($0.kind) && myLikedNoteIds.contains($0.id) }
                    filtered.sort { (myLikeDates[$0.id] ?? Date.distantPast) > (myLikeDates[$1.id] ?? Date.distantPast) }

                    let result = Self.applySearchFilter(to: filtered, search: currentSearch, scope: currentScope)

                    guard await MainActor.run(body: { gen == self.updateGeneration }) else { return }
                    await MainActor.run {
                        let newDisplay = Array(result.prefix(self.maxDisplayedItems))
                        if self.displayLikedNotes.map({ $0.id }) != newDisplay.map({ $0.id }) {
                            self.displayLikedNotes = newDisplay
                        }
                        if !self.reactionMap.isEmpty { self.reactionMap = [:] }
                        if !newDisplay.isEmpty { self.likesHasLoadedOnce = true }
                    }
                } else {
                    // Incoming reactions: determine target note set based on filter
                    let targetNoteIds: Set<String>
                    switch currentLikesFilter {
                    case .onMyNotes:
                        targetNoteIds = Set(currentEvents.filter { $0.pubkey == owner && noteKinds.contains($0.kind) }.map { $0.id })
                    case .onTagged:
                        targetNoteIds = Set(currentEvents.filter {
                            noteKinds.contains($0.kind) &&
                            $0.pubkey != owner &&
                            $0.tags.contains { $0.count >= 2 && $0[0] == "p" && $0[1] == owner }
                        }.map { $0.id })
                    case .onWhitelisted:
                        targetNoteIds = Set(currentEvents.filter {
                            noteKinds.contains($0.kind) &&
                            whitelist.contains($0.pubkey)
                        }.map { $0.id })
                    case .myLikes:
                        targetNoteIds = [] // handled above
                    }

                    // Build reaction map: noteId -> [(pubkey, emoji)] + track newest reaction time per note
                    var rxMap: [String: [(pubkey: String, emoji: String)]] = [:]
                    var latestReaction: [String: Date] = [:]
                    let excludeSelf = (currentLikesFilter == .onMyNotes)
                    for event in currentEvents where event.kind == 7 {
                        if excludeSelf && event.pubkey == owner { continue }
                        if let targetId = event.tags.first(where: { $0.count >= 2 && $0[0] == "e" && targetNoteIds.contains($0[1]) })?[1] {
                            let emoji = event.content.isEmpty ? "+" : event.content
                            rxMap[targetId, default: []].append((pubkey: event.pubkey, emoji: emoji))
                            let d = event.createdAtDate
                            if let existing = latestReaction[targetId] {
                                if d > existing { latestReaction[targetId] = d }
                            } else {
                                latestReaction[targetId] = d
                            }
                        }
                    }

                    let likedNoteIds = Set(rxMap.keys)
                    var filtered = currentEvents.filter { noteKinds.contains($0.kind) && likedNoteIds.contains($0.id) }
                    // Sort by newest reaction first, tiebreaking by note date
                    filtered.sort {
                        let d0 = latestReaction[$0.id] ?? Date.distantPast
                        let d1 = latestReaction[$1.id] ?? Date.distantPast
                        if d0 == d1 { return $0.createdAtDate > $1.createdAtDate }
                        return d0 > d1
                    }

                    let result = Self.applySearchFilter(to: filtered, search: currentSearch, scope: currentScope)

                    let finalRxMap = rxMap
                    let finalReactionDates = latestReaction
                    guard await MainActor.run(body: { gen == self.updateGeneration }) else { return }
                    await MainActor.run {
                        let newDisplay = Array(result.prefix(self.maxDisplayedItems))
                        if self.displayLikedNotes.map({ $0.id }) != newDisplay.map({ $0.id }) {
                            self.displayLikedNotes = newDisplay
                        }
                        self.reactionMap = finalRxMap
                        self.latestReactionDates = finalReactionDates
                        if !newDisplay.isEmpty { self.likesHasLoadedOnce = true }
                    }
                }
            } else if currentMode == .zaps {
                // MARK: - Zaps Mode (cached parsing)
                let noteKinds = [1, 6, 30023]
                let zapReceipts = currentEvents.filter { $0.kind == 9735 }

                // Parse all zap receipts, using cache for already-parsed ones
                let existingCache = await MainActor.run { self.zapReceiptCache }
                var newCacheEntries: [String: ParsedZapReceipt] = [:]
                var parsedReceipts: [(receiptId: String, parsed: ParsedZapReceipt)] = []
                parsedReceipts.reserveCapacity(zapReceipts.count)

                for receipt in zapReceipts {
                    if let cached = existingCache[receipt.id] {
                        parsedReceipts.append((receipt.id, cached))
                    } else {
                        guard let descJson = receipt.tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
                              let descData = descJson.data(using: .utf8),
                              let zapReq = try? JSONSerialization.jsonObject(with: descData) as? [String: Any],
                              let senderPubkey = zapReq["pubkey"] as? String else { continue }
                        let targetId = receipt.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1]
                        var amountSats: Int64 = 0
                        if let reqTags = zapReq["tags"] as? [[String]],
                           let amountTag = reqTags.first(where: { $0.count >= 2 && $0[0] == "amount" }),
                           let msats = Int64(amountTag[1]) {
                            amountSats = msats / 1000
                        }
                        let parsed = ParsedZapReceipt(senderPubkey: senderPubkey, targetNoteId: targetId, amountSats: amountSats)
                        newCacheEntries[receipt.id] = parsed
                        parsedReceipts.append((receipt.id, parsed))
                    }
                }

                if !newCacheEntries.isEmpty {
                    let entries = newCacheEntries
                    await MainActor.run {
                        for (key, value) in entries {
                            self.zapReceiptCache[key] = value
                        }
                    }
                }

                if currentZapsFilter == .myZaps {
                    // My Zaps: notes I zapped
                    let myZappedNoteIds = Set(parsedReceipts.compactMap { item -> String? in
                        guard item.parsed.senderPubkey == owner else { return nil }
                        return item.parsed.targetNoteId
                    })
                    let filtered = currentEvents.filter { noteKinds.contains($0.kind) && myZappedNoteIds.contains($0.id) }

                    let result = Self.applySearchFilter(to: filtered, search: currentSearch, scope: currentScope)

                    guard await MainActor.run(body: { gen == self.updateGeneration }) else { return }
                    await MainActor.run {
                        let newDisplay = Array(result.prefix(self.maxDisplayedItems))
                        if self.displayZappedNotes.map({ $0.id }) != newDisplay.map({ $0.id }) {
                            self.displayZappedNotes = newDisplay
                        }
                        if !self.zapMap.isEmpty { self.zapMap = [:] }
                        if !newDisplay.isEmpty { self.zapsHasLoadedOnce = true }
                    }
                } else {
                    // Incoming zaps: determine target note set based on filter
                    let targetNoteIds: Set<String>
                    switch currentZapsFilter {
                    case .onMyNotes:
                        targetNoteIds = Set(currentEvents.filter { $0.pubkey == owner && noteKinds.contains($0.kind) }.map { $0.id })
                    case .onTagged:
                        targetNoteIds = Set(currentEvents.filter {
                            noteKinds.contains($0.kind) &&
                            $0.pubkey != owner &&
                            $0.tags.contains { $0.count >= 2 && $0[0] == "p" && $0[1] == owner }
                        }.map { $0.id })
                    case .onWhitelisted:
                        targetNoteIds = Set(currentEvents.filter {
                            noteKinds.contains($0.kind) &&
                            whitelist.contains($0.pubkey)
                        }.map { $0.id })
                    case .myZaps:
                        targetNoteIds = [] // handled above
                    }

                    let excludeSelf = (currentZapsFilter == .onMyNotes)
                    var zMap: [String: [(pubkey: String, amount: Int64)]] = [:]
                    for item in parsedReceipts {
                        guard let targetId = item.parsed.targetNoteId,
                              targetNoteIds.contains(targetId) else { continue }
                        if excludeSelf && item.parsed.senderPubkey == owner { continue }
                        zMap[targetId, default: []].append((pubkey: item.parsed.senderPubkey, amount: item.parsed.amountSats))
                    }

                    let zappedNoteIds = Set(zMap.keys)
                    var filtered = currentEvents.filter { noteKinds.contains($0.kind) && zappedNoteIds.contains($0.id) }
                    let zapTotals = { (noteId: String) -> Int64 in
                        zMap[noteId]?.reduce(0) { $0 + $1.amount } ?? 0
                    }
                    filtered.sort { zapTotals($0.id) > zapTotals($1.id) }

                    let result = Self.applySearchFilter(to: filtered, search: currentSearch, scope: currentScope)

                    let finalZMap = zMap
                    guard await MainActor.run(body: { gen == self.updateGeneration }) else { return }
                    await MainActor.run {
                        let newDisplay = Array(result.prefix(self.maxDisplayedItems))
                        if self.displayZappedNotes.map({ $0.id }) != newDisplay.map({ $0.id }) {
                            self.displayZappedNotes = newDisplay
                        }
                        self.zapMap = finalZMap
                        if !newDisplay.isEmpty { self.zapsHasLoadedOnce = true }
                    }
                }
            } else if currentMode == .notes {
                // MARK: - Notes Mode (Kinds: 1, 30023)
                let filtered = currentEvents.filter { event in
                    let validKinds = [1, 30023]
                    if !validKinds.contains(event.kind) { return false }

                    if blacklist.contains(event.pubkey) { return false }

                    switch currentFilter {
                    case .all:
                        let isMine = event.pubkey == owner
                        let isTagged = event.tags.contains { $0.count >= 2 && $0[0] == "p" && $0[1] == owner }
                        let isWhitelisted = whitelist.contains(event.pubkey)
                        return isMine || isTagged || isWhitelisted
                    case .mine: return event.pubkey == owner
                    case .tagged: return event.pubkey != owner && event.tags.contains { $0.count >= 2 && $0[0] == "p" && $0[1] == owner }
                    case .whitelist:
                        return whitelist.contains(event.pubkey) && event.pubkey != owner
                    }
                }

                let result = Self.applySearchFilter(to: filtered, search: currentSearch, scope: currentScope)

                // Compute engagement data (reactions & zaps) for all displayed notes
                let displaySlice = Array(result.prefix(currentMaxDisplayed))
                let displayedIds = Set(displaySlice.map { $0.id })

                var rxMap: [String: [(pubkey: String, emoji: String)]] = [:]
                var latestReaction: [String: Date] = [:]
                if !displayedIds.isEmpty {
                    for event in currentEvents where event.kind == 7 {
                        if let targetId = event.tags.first(where: { $0.count >= 2 && $0[0] == "e" && displayedIds.contains($0[1]) })?[1] {
                            let emoji = event.content.isEmpty ? "+" : event.content
                            rxMap[targetId, default: []].append((pubkey: event.pubkey, emoji: emoji))
                            let d = event.createdAtDate
                            if let existing = latestReaction[targetId] {
                                if d > existing { latestReaction[targetId] = d }
                            } else {
                                latestReaction[targetId] = d
                            }
                        }
                    }
                }

                var zMap: [String: [(pubkey: String, amount: Int64)]] = [:]
                if !displayedIds.isEmpty {
                    let zapReceipts = currentEvents.filter { $0.kind == 9735 }
                    for receipt in zapReceipts {
                        guard let targetId = receipt.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1],
                              displayedIds.contains(targetId) else { continue }
                        guard let descJson = receipt.tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
                              let descData = descJson.data(using: .utf8),
                              let zapReq = try? JSONSerialization.jsonObject(with: descData) as? [String: Any],
                              let senderPubkey = zapReq["pubkey"] as? String else { continue }
                        var amountSats: Int64 = 0
                        if let reqTags = zapReq["tags"] as? [[String]],
                           let amountTag = reqTags.first(where: { $0.count >= 2 && $0[0] == "amount" }),
                           let msats = Int64(amountTag[1]) {
                            amountSats = msats / 1000
                        }
                        zMap[targetId, default: []].append((pubkey: senderPubkey, amount: amountSats))
                    }
                }

                // Repost map: noteId -> [reposter pubkeys]
                var rpMap: [String: [String]] = [:]
                if !displayedIds.isEmpty {
                    for event in currentEvents where event.kind == 6 {
                        if let targetId = event.tags.first(where: { $0.count >= 2 && $0[0] == "e" && displayedIds.contains($0[1]) })?[1] {
                            rpMap[targetId, default: []].append(event.pubkey)
                        }
                    }
                }

                // Quote map: noteId -> [quoter pubkeys]
                var qtMap: [String: [String]] = [:]
                if !displayedIds.isEmpty {
                    for event in currentEvents where event.kind == 1 {
                        if let targetId = event.tags.first(where: { $0.count >= 2 && $0[0] == "q" && displayedIds.contains($0[1]) })?[1] {
                            qtMap[targetId, default: []].append(event.pubkey)
                        }
                    }
                }

                let finalRxMap = rxMap
                let finalReactionDates = latestReaction
                let finalZMap = zMap
                let finalRpMap = rpMap
                let finalQtMap = qtMap

                // Skip UI update if a newer generation has been triggered
                guard await MainActor.run(body: { gen == self.updateGeneration }) else { return }

                await MainActor.run {
                    self.displayNotes = displaySlice
                    self.reactionMap = finalRxMap
                    self.latestReactionDates = finalReactionDates
                    self.zapMap = finalZMap
                    self.repostMap = finalRpMap
                    self.quoteMap = finalQtMap
                    self.notesHasLoadedOnce = true
                }
            } else {
                // Compute Media
                var latestItems: [String: MediaItem] = [:]

                let remoteItems = currentNoteMedia.filter { item in
                    if let pk = item.pubkey, blacklist.contains(pk) { return false }

                    switch currentFilter {
                    case .all:
                        if isOwnerBrowsing {
                            // Owner sees all media on the relay
                            return true
                        }
                        return item.pubkey == owner
                    case .mine: return item.pubkey == owner
                    case .tagged:
                        if item.pubkey == owner { return false }
                        return item.tags?.contains { $0.count >= 2 && $0[0] == "p" && $0[1] == owner } ?? false
                    case .whitelist:
                        guard let pk = item.pubkey else { return false }
                        return whitelist.contains(pk) && pk != owner
                    }
                }

                // Build hash → event timestamp lookup from ALL noteMedia (unfiltered)
                // so blossom items get correct dates even when no noteMedia match survives filtering
                var eventTimestamps: [String: Date] = [:]
                for item in currentNoteMedia {
                    let key = self.normalizedKeyStatic(for: item.url)
                    if let existing = eventTimestamps[key] {
                        if item.dateAdded > existing { eventTimestamps[key] = item.dateAdded }
                    } else {
                        eventTimestamps[key] = item.dateAdded
                    }
                }

                // Track every URL we've seen per hash so we can later prefer a mirror URL
                // for display (and for the Blossom/Cache/404 classification).
                var urlsByKey: [String: [URL]] = [:]
                let recordURL: (String, URL) -> Void = { key, url in
                    var existing = urlsByKey[key] ?? []
                    if !existing.contains(url) { existing.append(url) }
                    urlsByKey[key] = existing
                }

                // Add blossom items first — they have accurate mime detection from local bytes + relay
                // Apply event timestamps where available instead of file modification dates
                if currentFilter == .all || currentFilter == .mine {
                    for item in currentBlossom {
                        // Whitelisted accounts only see their own blossom items + items tagging them
                        if !isOwnerBrowsing && currentFilter == .all {
                            let isMine = item.pubkey == owner
                            let isTagged = item.tags?.contains { $0.count >= 2 && $0[0] == "p" && $0[1] == owner } ?? false
                            if !isMine && !isTagged { continue }
                        }
                        let key = self.normalizedKeyStatic(for: item.url)
                        recordURL(key, item.url)
                        if let eventDate = eventTimestamps[key] {
                            latestItems[key] = MediaItem(
                                id: item.id,
                                url: item.url,
                                type: item.type,
                                dateAdded: eventDate,
                                pubkey: item.pubkey,
                                tags: item.tags,
                                mimeType: item.mimeType
                            )
                        } else {
                            latestItems[key] = item
                        }
                    }
                }

                for item in remoteItems {
                    let key = self.normalizedKeyStatic(for: item.url)
                    recordURL(key, item.url)
                    if let existing = latestItems[key] {
                        // Blossom item exists — keep its superior mime detection
                        // but use the nostr event's created_at as the authoritative date
                        latestItems[key] = MediaItem(
                            id: existing.id,
                            url: existing.url,
                            type: existing.type,
                            dateAdded: item.dateAdded, // event timestamp
                            pubkey: item.pubkey ?? existing.pubkey,
                            tags: item.tags ?? existing.tags,
                            mimeType: existing.mimeType ?? item.mimeType
                        )
                    } else {
                        latestItems[key] = item
                    }
                }

                // Promote each merged item to its best display URL.
                // Priority: known mirror URL > current URL > any other recorded URL.
                // This makes the Blossom filter pick up locally-stored items whose canonical
                // URL is on a configured mirror.
                let mirrorHostsCapture = currentMirrorHosts
                let macHostCapture = URL(string: macRelayHttps)?.host?.lowercased()
                let isOnMirror: (URL) -> Bool = { url in
                    guard let host = url.host?.lowercased() else { return false }
                    if mirrorHostsCapture.contains(host) { return true }
                    if host == "127.0.0.1" || host == "localhost" || host == "0.0.0.0" { return true }
                    if let macHost = macHostCapture, host == macHost { return true }
                    return false
                }
                for (key, item) in latestItems {
                    let candidates = urlsByKey[key] ?? [item.url]
                    if !isOnMirror(item.url), let mirrorURL = candidates.first(where: isOnMirror) {
                        latestItems[key] = MediaItem(
                            id: item.id,
                            url: mirrorURL,
                            type: item.type,
                            dateAdded: item.dateAdded,
                            pubkey: item.pubkey,
                            tags: item.tags,
                            mimeType: item.mimeType
                        )
                    }
                }
                
                // Merge and filter all items directly
                let allItems = Array(latestItems.values)
                let hasEventTimestamp = Set(eventTimestamps.keys)

                // Filter by media type
                let typeFilterSet = currentTypeFilter
                let isGif = { (item: MediaItem) -> Bool in
                    let ext = item.url.pathExtension.lowercased()
                    return ext == "gif" || item.mimeType?.lowercased().contains("gif") == true
                }

                var filtered = allItems.filter { item in
                    if isGif(item) { return typeFilterSet.contains(.gif) }
                    switch item.type {
                    case .image: return typeFilterSet.contains(.photo)
                    case .video: return typeFilterSet.contains(.video)
                    case .audio: return typeFilterSet.contains(.other)
                    case .unknown: return typeFilterSet.contains(.other)
                    }
                }

                // Apply location filter: blossom (physically in local blossom directory) /
                // cache (cached from feed, not in blossom) / notFound (user-flagged 404) /
                // all (blossom+cache).
                let notFoundCapture = currentNotFound
                let locationFilter = currentLocationFilter
                let passesLocation: (MediaItem) -> Bool = { item in
                    let is404 = notFoundCapture.contains(item.url.absoluteString)

                    // Check if file is actually in the local blossom directory
                    let hash = self.normalizedKeyStatic(for: item.url)
                    let inBlossomDir = MediaCacheService.shared.isInLocalBlossom(hash: hash)

                    switch locationFilter {
                    case .all: return !is404
                    case .blossom: return inBlossomDir && !is404
                    case .cache: return !inBlossomDir && !is404
                    case .notFound: return is404
                    }
                }
                filtered = filtered.filter(passesLocation)

                // Sort by date added, newest first
                filtered.sort(by: { $0.dateAdded > $1.dateAdded })
                var result = filtered

                #if DEBUG
                let timestampCount = eventTimestamps.count
                let blossomWithTimestamp = currentBlossom.filter { hasEventTimestamp.contains(self.normalizedKeyStatic(for: $0.url)) }.count
                let timestampedCount = allItems.filter { hasEventTimestamp.contains(self.normalizedKeyStatic(for: $0.url)) || !self.isLocalBlossomURL($0.url) }.count
                let unmatchedCount = allItems.count - timestampedCount
                print("updateDisplayData: eventTimestamps=\(timestampCount) blossomMatched=\(blossomWithTimestamp)/\(currentBlossom.count) timestamped=\(timestampedCount) unmatched=\(unmatchedCount)")
                if let first = result.first {
                    let df = DateFormatter()
                    df.dateFormat = "MM/dd HH:mm"
                    print("  first: \(df.string(from: first.dateAdded)) url=\(first.url.lastPathComponent.prefix(12))")
                }
                #endif

                // Fix up items with missing or octet-stream mime types by sniffing remote bytes
                // This is now synchronous and skips remote sniffing for performance
                for i in result.indices {
                    let item = result[i]
                    let needsSniff = item.type == .unknown ||
                        (item.mimeType == nil && item.url.pathExtension.isEmpty) ||
                        item.mimeType?.lowercased() == "application/octet-stream"
                    if needsSniff {
                        let ext = item.url.pathExtension.lowercased()
                        var sniffedType: MediaItem.MediaType = .unknown
                        var sniffedMime: String? = nil
                        
                        if let mime = SupportedMediaFormats.mime(forExtension: ext) {
                            switch SupportedMediaFormats.category(forExtension: ext) {
                            case .image, .gif: sniffedType = .image
                            case .video:       sniffedType = .video
                            case .audio:       sniffedType = .audio
                            case .none:        break
                            }
                            sniffedMime = mime
                        }
                        
                        if sniffedType != .unknown {
                            result[i] = MediaItem(id: item.id, url: item.url, type: sniffedType, dateAdded: item.dateAdded, pubkey: item.pubkey, tags: item.tags, mimeType: sniffedMime)
                        }
                    }
                }

                let finalResult = result

                // Skip UI update if a newer generation has been triggered
                guard await MainActor.run(body: { gen == self.updateGeneration }) else { return }

                await MainActor.run {
                    self.displayMedia = Array(finalResult.prefix(self.maxDisplayedItems))
                    self.mediaHasLoadedOnce = true
                }
            }

            // Profile search (independent of view mode)
            if currentScope == .profiles && !currentSearch.isEmpty {
                let allProfiles = await MainActor.run { Array(self.nostrService.profiles.values) }
                let query = currentSearch.lowercased()
                let matched = allProfiles.filter { profile in
                    (profile.name?.lowercased().contains(query) ?? false)
                    || (profile.displayName?.lowercased().contains(query) ?? false)
                    || (profile.nip05?.lowercased().contains(query) ?? false)
                    || (profile.about?.lowercased().contains(query) ?? false)
                }
                let sorted = matched.sorted { a, b in
                    let aName = a.bestName.lowercased()
                    let bName = b.bestName.lowercased()
                    let aPrefix = aName.hasPrefix(query)
                    let bPrefix = bName.hasPrefix(query)
                    if aPrefix != bPrefix { return aPrefix }
                    return aName < bName
                }
                let profileSlice = Array(sorted.prefix(50))
                guard await MainActor.run(body: { gen == self.updateGeneration }) else { return }
                await MainActor.run {
                    self.displayProfileResults = profileSlice
                }
            } else {
                guard await MainActor.run(body: { gen == self.updateGeneration }) else { return }
                await MainActor.run {
                    if !self.displayProfileResults.isEmpty {
                        self.displayProfileResults = []
                    }
                }
            }
        }
    }
    
    // Check if URL points to the local blossom server (127.0.0.1 or localhost)
    private nonisolated func isLocalBlossomURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "0.0.0.0"
    }

    // Helper for detached task
    private nonisolated func normalizedKeyStatic(for url: URL) -> String {
        let urlString = url.absoluteString
        let lastComponent = url.lastPathComponent
        if lastComponent.count == 64 && lastComponent.allSatisfy({ $0.isHexDigit }) {
             return lastComponent
        }
        if let match = Self.hexPattern.firstMatch(in: urlString, options: [], range: NSRange(urlString.startIndex..., in: urlString)),
           let range = Range(match.range, in: urlString) {
            return String(urlString[range])
        }
        return url.deletingPathExtension().lastPathComponent
    }
    
    var statusColor: Color {
        switch nostrService.connectionColor {
        case "green": return .green
        case "yellow": return .yellow
        case "red": return .red
        default: return .gray
        }
    }
    
    private var viewModeTitle: String {
        switch viewMode {
        case .notes: return "Notes"
        case .media: return "Media"
        case .likes: return "Likes"
        case .zaps: return "Zaps"
        }
    }
    
    var body: some View {
        #if os(iOS)
        NavigationStack(path: $navigationPath) {
            iOSContent
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .navigationDestination(for: FeedNote.self) { note in
                    NoteDetailView(note: note)
                }
        }
        #else
        viewContent
        #endif
    }

    // MARK: - iOS Root Content
    /// Flat content view matching FeedView's rootContent pattern:
    /// toolbar + handlers first, navigation modifiers applied in body.
    private var iOSContent: some View {
        viewContentPlatform
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if !mediaOnly {
                    HStack(spacing: 12) {
                        IconFilterButton(icon: "doc.text", tooltip: "Notes", isSelected: viewMode == .notes, color: .havenPurple) {
                            withAnimation(.easeInOut(duration: 0.15)) { viewMode = .notes }
                        }
                        IconFilterButton(icon: "heart.fill", tooltip: "Likes", isSelected: viewMode == .likes, color: .havenPurple) {
                            withAnimation(.easeInOut(duration: 0.15)) { viewMode = .likes }
                            fetchMissingLikedNotes()
                        }
                        IconFilterButton(icon: "bolt.fill", tooltip: "Zaps", isSelected: viewMode == .zaps, color: .havenPurple) {
                            withAnimation(.easeInOut(duration: 0.15)) { viewMode = .zaps }
                        }
                    }
                } else {
                    HStack(spacing: 12) {
                        let allSelected = mediaTypeFilter.count == MediaTypeFilter.allCases.count
                        let photoSelected = mediaTypeFilter.contains(.photo)
                        let videoSelected = mediaTypeFilter.contains(.video)
                        let gifSelected = mediaTypeFilter.contains(.gif)
                        let otherSelected = mediaTypeFilter.contains(.other)

                        IconFilterButton(
                            icon: allSelected ? "circle.grid.2x2.fill" : "circle.grid.2x2",
                            tooltip: "All Media",
                            isSelected: allSelected,
                            color: .havenPurple,
                            action: selectAllMediaTypes
                        )
                        IconFilterButton(
                            icon: photoSelected ? "photo.fill" : "photo",
                            tooltip: "Photos",
                            isSelected: photoSelected,
                            color: .primary
                        ) { toggleMediaTypeFilter(.photo) }
                        IconFilterButton(
                            icon: videoSelected ? "video.fill" : "video",
                            tooltip: "Videos",
                            isSelected: videoSelected,
                            color: .primary
                        ) { toggleMediaTypeFilter(.video) }
                        IconFilterButton(
                            icon: "GIF",
                            tooltip: "GIFs",
                            isSelected: gifSelected,
                            color: .primary
                        ) { toggleMediaTypeFilter(.gif) }
                        IconFilterButton(
                            icon: otherSelected ? "doc.fill" : "doc",
                            tooltip: "Documents",
                            isSelected: otherSelected,
                            color: .primary
                        ) { toggleMediaTypeFilter(.other) }
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 4) {
                    if !mediaOnly && viewMode != .media {
                        IconFilterButton(
                            icon: "rectangle.compress.vertical",
                            tooltip: "Condensed View",
                            isSelected: noteLayoutMode == .compact,
                            color: .havenPurple
                        ) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                noteLayoutMode = noteLayoutMode == .compact ? .expanded : .compact
                            }
                        }
                    }
                    if viewMode == .notes {
                        HStack(spacing: 4) {
                            IconFilterButton(icon: "square.stack", tooltip: "All", isSelected: contentFilter == .all, color: .havenPurple) { contentFilter = .all }
                            IconFilterButton(icon: "person.fill", tooltip: "My Notes", isSelected: contentFilter == .mine, color: .havenPurple) { contentFilter = .mine }
                            IconFilterButton(icon: "at", tooltip: "Tagged", isSelected: contentFilter == .tagged, color: .havenPurple) { contentFilter = .tagged }
                            IconFilterButton(icon: "checkmark.seal.fill", tooltip: "Whitelisted", isSelected: contentFilter == .whitelist, color: .havenPurple) { contentFilter = .whitelist }
                        }
                        .transition(.opacity)
                    } else if viewMode == .media && !mediaOnly {
                        HStack(spacing: 4) {
                            IconFilterButton(icon: "plus", tooltip: "Upload", isSelected: true, color: .havenPurple) {
                                showingUploadOptions = true
                            }
                            .confirmationDialog("Upload Media", isPresented: $showingUploadOptions) {
                                Button("Photos") {
                                    photosPickerFilter = .images
                                    showingPhotoPicker = true
                                }
                                Button("Videos") {
                                    photosPickerFilter = .videos
                                    showingPhotoPicker = true
                                }
                                Button("Files") {
                                    showingFileImporter = true
                                }
                                Button("Magic Paste") {
                                    handlePasteFromClipboard()
                                }
                                Button("Cancel", role: .cancel) { }
                            }
                        }
                        .transition(.opacity)
                    } else if mediaOnly {
                        HStack(spacing: 4) {
                            IconFilterButton(
                                icon: mediaLayoutMode == .grid ? "list.bullet" : "square.grid.2x2.fill",
                                tooltip: mediaLayoutMode == .grid ? "List View" : "Grid View",
                                isSelected: false,
                                color: .havenPurple
                            ) {
                                withAnimation {
                                    mediaLayoutMode = mediaLayoutMode == .grid ? .list : .grid
                                }
                            }

                            IconFilterButton(icon: "plus", tooltip: "Upload Options", isSelected: true, color: .havenPurple) {
                                showingUploadOptions = true
                            }
                            .confirmationDialog("Upload Media", isPresented: $showingUploadOptions) {
                                Button("Photos") {
                                    photosPickerFilter = .images
                                    showingPhotoPicker = true
                                }
                                Button("Videos") {
                                    photosPickerFilter = .videos
                                    showingPhotoPicker = true
                                }
                                Button("Files") {
                                    showingFileImporter = true
                                }
                                Button("Magic Paste") {
                                    handlePasteFromClipboard()
                                }
                                Button("Cancel", role: .cancel) { }
                            }
                        }
                        .transition(.opacity)
                    } else if viewMode == .likes {
                        HStack(spacing: 4) {
                            IconFilterButton(icon: "person.fill", tooltip: "My Notes", isSelected: likesFilter == .onMyNotes, color: .havenPurple) { likesFilter = .onMyNotes }
                            IconFilterButton(icon: "at", tooltip: "Tagged", isSelected: likesFilter == .onTagged, color: .havenPurple) { likesFilter = .onTagged }
                            IconFilterButton(icon: "checkmark.seal.fill", tooltip: "Whitelisted", isSelected: likesFilter == .onWhitelisted, color: .havenPurple) { likesFilter = .onWhitelisted }
                            IconFilterButton(icon: "heart", tooltip: "My Likes", isSelected: likesFilter == .myLikes, color: .havenPurple) { likesFilter = .myLikes }
                        }
                        .transition(.opacity)
                    } else if viewMode == .zaps && !mediaOnly {
                        HStack(spacing: 4) {
                            IconFilterButton(icon: "person.fill", tooltip: "My Notes", isSelected: zapsFilter == .onMyNotes, color: .havenPurple) { zapsFilter = .onMyNotes }
                            IconFilterButton(icon: "at", tooltip: "Tagged", isSelected: zapsFilter == .onTagged, color: .havenPurple) { zapsFilter = .onTagged }
                            IconFilterButton(icon: "checkmark.seal.fill", tooltip: "Whitelisted", isSelected: zapsFilter == .onWhitelisted, color: .havenPurple) { zapsFilter = .onWhitelisted }
                            IconFilterButton(icon: "bolt", tooltip: "My Zaps", isSelected: zapsFilter == .myZaps, color: .havenPurple) { zapsFilter = .myZaps }
                        }
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: viewMode)
            }
        }
        // -- handlers from viewContentBase --
        .onAppear {
            if relayManager.isRunning && !relayManager.isBooting {
                if !mediaOnly && feedService.followedPubkeys.isEmpty {
                    feedService.refresh()
                }
                let recentlyReconnected: Bool
                if let lastReconnect = nostrService.lastForegroundReconnectTime {
                    recentlyReconnected = Date().timeIntervalSince(lastReconnect) < 3.0
                } else {
                    recentlyReconnected = false
                }
                if nostrService.connectionStatus == "Disconnected" && !recentlyReconnected {
                    refreshAll()
                }
                initialLoad = true
                updateDisplayData()
            }
            if !mediaOnly && !hasEstablishedNotificationBaseline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    establishNotificationBaseline()
                }
            }
        }
        .onChange(of: relayManager.isBooting) { _, isBooting in
            if !isBooting && relayManager.isRunning {
                refreshAll()
                initialLoad = true
                triggerAutoMirrorIfEnabled()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    establishNotificationBaseline()
                }
            }
        }
        .onChange(of: relayManager.isRunning) { _, isRunning in
            if isRunning && !relayManager.isBooting {
                refreshAll()
                initialLoad = true
            }
        }
        .onChange(of: selectedMedia) { _, _ in
            isCopied = false
        }
        #if os(iOS)
        .fullScreenCover(isPresented: isPresentingViewer) {
            if let item = selectedMedia {
                mediaViewerContent(for: item)
            }
        }
        #else
        // macOS has no fullScreenCover — present the media viewer as a sheet.
        .sheet(isPresented: isPresentingViewer) {
            if let item = selectedMedia {
                mediaViewerContent(for: item)
            }
        }
        #endif
        // -- handlers from viewContentWithHandlers --
        .modifier(ViewerChangeHandlers(
            viewMode: viewMode,
            likesFilter: likesFilter,
            zapsFilter: zapsFilter,
            committedSearch: committedSearch,
            searchScope: searchScope,
            contentFilter: contentFilter,
            mediaSourceFilter: mediaSourceFilter,
            mediaLocationFilter: mediaLocationFilter,
            mediaTypeFilter: mediaTypeFilter,
            eventsCount: nostrService.events.count,
            noteMediaCount: nostrService.noteMedia.count,
            blacklistedNpubs: configService.config.blockedNpubsPerAccount[configService.config.activeAccountNpub.isEmpty ? configService.config.ownerNpub : configService.config.activeAccountNpub] ?? (configService.config.activeAccountNpub.isEmpty ? configService.config.blacklistedNpubs : []),
            activeAccountNpub: configService.config.activeAccountNpub,
            blossomCount: blossomCache.items.count,
            onResetAndUpdate: {
                maxDisplayedItems = 50
                notesHasLoadedOnce = false
                mediaHasLoadedOnce = false
                scheduleUpdateDisplayData()
            },
            onUpdate: { scheduleUpdateDisplayData() },
            onViewModeChange: { newMode in
                updateDisplayData()
                markTabViewed(newMode)
                if newMode == .likes {
                    fetchMissingLikedNotes()
                    updateLikesSettleState()
                }
                if newMode == .zaps {
                    fetchMoreZapReceipts()
                    fetchMissingZappedNotes()
                    updateZapsSettleState()
                }
            },
            onEventsChange: {
                scheduleUpdateDisplayData()
                checkForNewNotifications()
                if viewMode == .likes && likesFilter == .myLikes {
                    fetchMissingLikedNotes()
                }
                if viewMode == .zaps {
                    fetchMissingZappedNotes()
                }
            }
        ))
        .onChange(of: likesFilter) { _, _ in
            likesHasLoadedOnce = false
            likesInitialSettled = false
            updateLikesSettleState()
        }
        .onChange(of: zapsFilter) { _, _ in
            zapsHasLoadedOnce = false
            zapsInitialSettled = false
            updateZapsSettleState()
        }
        .onChange(of: configService.config.activeAccountNpub) { _, _ in
            notesHasLoadedOnce = false
            mediaHasLoadedOnce = false
            likesHasLoadedOnce = false
            likesInitialSettled = false
            zapsHasLoadedOnce = false
            zapsInitialSettled = false
            hasFetchedZapReceipts = false
            zapReceiptCache = [:]
            refreshAll()
        }
        .onChange(of: nostrService.isFetching) { _, _ in
            if viewMode == .likes { updateLikesSettleState() }
            if viewMode == .zaps { updateZapsSettleState() }
        }
        .onChange(of: relayManager.isBooting) { _, _ in
            if viewMode == .likes { updateLikesSettleState() }
            if viewMode == .zaps { updateZapsSettleState() }
        }
        // -- handlers from viewContent --
        .onReceive(MirrorService.shared.$state) { newState in
            if newState == .complete {
                loadLocalMedia(force: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .feedInjectionComplete)) { _ in
            refreshAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaNotFoundChanged)) { _ in
            scheduleUpdateDisplayData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .blossomDirectoryChanged)) { _ in
            loadLocalMedia(force: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openRelayDashboard)) { _ in
            showingRelayDashboard = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayLikes)) { _ in
            guard !mediaOnly else { return }
            withAnimation(.easeInOut(duration: 0.15)) { viewMode = .likes }
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayNotes)) { _ in
            guard !mediaOnly else { return }
            withAnimation(.easeInOut(duration: 0.15)) { viewMode = .notes }
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayZaps)) { _ in
            guard !mediaOnly else { return }
            withAnimation(.easeInOut(duration: 0.15)) { viewMode = .zaps }
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { showingProfilePubkey.map { IdentifiableString(id: $0) } },
            set: { showingProfilePubkey = $0?.id }
        )) { p in
            ProfileView(pubkey: p.id, onDismiss: { showingProfilePubkey = nil })
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { showingNoteId.map { IdentifiableString(id: $0) } },
            set: { showingNoteId = $0?.id }
        )) { noteId in
            NoteDetailViewWrapper(noteId: noteId.id, onDismiss: { showingNoteId = nil })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(isPresented: $showingRelayDashboard) {
            NavigationView {
                DashboardView()
                    .environmentObject(relayManager)
                    .environmentObject(configService)
                    .environmentObject(nostrService)
                    .environmentObject(StatsService.shared)
                    .navigationTitle("")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingRelayDashboard = false }
                        }
                    }
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.image, .movie],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                handleUploadFileURLs(urls)
            case .failure(let error):
                print("Failed to select files: \(error)")
            }
        }
        .photosPicker(
            isPresented: $showingPhotoPicker,
            selection: $selectedUploadItems,
            matching: photosPickerFilter
        )
        .onChange(of: selectedUploadItems) { _, items in
            if !items.isEmpty {
                handleUploadSelectedItems(items)
                showingPhotoPicker = false
            }
        }
        .sheet(isPresented: $showingBlossomMediaList) {
            BlossomDashboardView()
                .environmentObject(configService)
                .environmentObject(nostrService)
        }
    }
    @ViewBuilder
    private func headerView(isNarrow: Bool) -> some View {
        if mediaOnly || embedded {
            EmptyView()
        } else {
            VStack(spacing: 12) {
                #if os(macOS)
                if isNarrow {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            modeView
                            Spacer()
                        }
                        if viewMode == .notes {
                            ScrollView(.horizontal, showsIndicators: false) {
                                filterView
                            }
                        } else if viewMode == .likes {
                            ScrollView(.horizontal, showsIndicators: false) {
                                likesFilterView
                            }
                        } else if viewMode == .zaps {
                            ScrollView(.horizontal, showsIndicators: false) {
                                zapsFilterView
                            }
                        }
                    }
                } else {
                    HStack {
                        modeView
                        Spacer()
                        if viewMode == .notes {
                            filterView
                        } else if viewMode == .likes {
                            likesFilterView
                        } else if viewMode == .zaps {
                            zapsFilterView
                        }
                        compactToggleButton
                    }
                }
                #else
                if viewMode == .media {
                    sourceFilterView
                }
                #endif

            }
            .frame(maxWidth: .infinity)
            #if os(macOS)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color.platformSecondaryGroupedBackground)
            #else
            .padding(.horizontal, viewMode == .media ? 16 : 0)
            .padding(.vertical, viewMode == .media ? 10 : 0)
            .background(viewMode == .media ? Color.platformSecondaryGroupedBackground : Color.clear)
            #endif
        }
    }


    private var currentPageTitle: String {
        switch viewMode {
        case .notes:
            switch contentFilter {
            case .all: return ""
            case .mine: return "My Notes"
            case .tagged: return "Notes I'm Tagged In"
            case .whitelist: return "Whitelisted Notes"
            }
        case .media:
            return mediaOnly ? "" : "Media"
        case .likes:
            switch likesFilter {
            case .onMyNotes: return "Likes on My Notes"
            case .onTagged: return "Likes on Tagged Notes"
            case .onWhitelisted: return "Likes on Whitelisted Notes"
            case .myLikes: return "Notes I've Liked"
            }
        case .zaps:
            switch zapsFilter {
            case .onMyNotes: return "Zaps on My Notes"
            case .onTagged: return "Zaps on Tagged Notes"
            case .onWhitelisted: return "Zaps on Whitelisted Notes"
            case .myZaps: return "Notes I've Zapped"
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        VStack(spacing: 0) {
            Group {
                if searchScope == .profiles && !committedSearch.isEmpty {
                    profileSearchResults
                } else if viewMode == .notes {
                    notesList
                } else if viewMode == .likes {
                    likesList
                } else if viewMode == .zaps {
                    zapsList
                } else {
                    mediaGrid
                }
            }
            .animation(.none, value: viewMode)
            .id("\(viewMode)-\(searchScope)-\(committedSearch.isEmpty)")
        }
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var viewContentPlatform: some View {
        #if os(iOS)
        if mediaOnly {
            // Full-bleed layout: ScrollView in a ZStack so content scrolls
            // behind the transparent navigation bar, enabling the glass toolbar effect.
            ZStack {
                Color.platformWindowBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        listContent

                        if !displayMedia.isEmpty {
                            Color.clear
                                .frame(height: 1)
                                .padding(.bottom, 20)
                                .onAppear {
                                    if !nostrService.isFetching {
                                        loadMore()
                                    }
                                }
                                .id(nostrService.events.count)
                        }
                    }
                    .tabBarBottomPadding()
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable {
                    refreshAll()
                }
                .scrollDirectionTracking(feedService: feedService)
            }
            .overlay(alignment: .bottomTrailing) {
                if !feedService.feedScrollingDown {
                    Button(action: { showingBlossomMediaList = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "camera.macro")
                                .font(.appSystem(size: 15, weight: .bold))
                            Text("Blossom")
                                .font(.appSystem(size: 14, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .frame(height: 48)
                        .padding(.horizontal, 18)
                        .background(
                            Capsule()
                                .fill(Color.havenPurple)
                                .shadow(color: Color.havenPurple.opacity(0.35), radius: 8, x: 0, y: 4)
                        )
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 90)
                    .hoverEffect(.lift)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: feedService.feedScrollingDown)
        } else {
            // Relay tab: full-bleed layout so content scrolls behind
            // the transparent navigation bar, matching the glass toolbar effect.
            ZStack {
                Color.platformWindowBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        listContent

                        if !displayNotes.isEmpty || !displayMedia.isEmpty || !displayLikedNotes.isEmpty {
                            Color.clear
                                .frame(height: 1)
                                .padding(.bottom, 20)
                                .onAppear {
                                    if !nostrService.isFetching && (!displayNotes.isEmpty || !displayMedia.isEmpty) {
                                        loadMore()
                                    }
                                }
                                .id(nostrService.events.count)
                        }
                    }
                    .tabBarBottomPadding()
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable {
                    refreshAll()
                }
                .scrollDirectionTracking(feedService: feedService)
            }
            .overlay(alignment: .bottomTrailing) {
                if !feedService.feedScrollingDown {
                    if viewMode == .media {
                        Button(action: { showingBlossomMediaList = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "chart.bar.fill")
                                    .font(.appSystem(size: 15, weight: .bold))
                                Text("Blossom")
                                    .font(.appSystem(size: 14, weight: .bold, design: .rounded))
                            }
                            .foregroundColor(.white)
                            .frame(height: 48)
                            .padding(.horizontal, 18)
                            .background(
                                Capsule()
                                    .fill(Color.havenPurple)
                                    .shadow(color: Color.havenPurple.opacity(0.35), radius: 8, x: 0, y: 4)
                            )
                        }
                        .padding(.trailing, 20)
                        .padding(.bottom, 90)
                        .hoverEffect(.lift)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                    } else {
                        Button(action: { showingRelayDashboard = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.appSystem(size: 15, weight: .bold))
                                Text("Relay")
                                    .font(.appSystem(size: 14, weight: .bold, design: .rounded))
                            }
                            .foregroundColor(.white)
                            .frame(height: 48)
                            .padding(.horizontal, 18)
                            .background(
                                Capsule()
                                    .fill(statusColor)
                                    .shadow(color: statusColor.opacity(0.35), radius: 8, x: 0, y: 4)
                            )
                        }
                        .padding(.trailing, 20)
                        .padding(.bottom, 90)
                        .hoverEffect(.lift)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: feedService.feedScrollingDown)
        }
        #else
        GeometryReader { geometry in
            ZStack {
                Color.platformWindowBackground.ignoresSafeArea()

                if mediaOnly {
                    compactViewContent(isNarrow: geometry.size.width < 500)
                } else if embedded {
                    // Embedded in sidebar: notes content with relay console pinned at bottom
                    VStack(spacing: 0) {
                        desktopHeaderView

                        Divider()

                        ScrollView {
                            listContent

                            if !displayNotes.isEmpty || !displayMedia.isEmpty || !displayLikedNotes.isEmpty {
                                Color.clear
                                    .frame(height: 1)
                                    .padding(.bottom, 20)
                                    .onAppear {
                                        if !nostrService.isFetching && (!displayNotes.isEmpty || !displayMedia.isEmpty) {
                                            loadMore()
                                        }
                                    }
                                    .id(nostrService.events.count)
                            }
                        }
                        .refreshable {
                            refreshAll()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        Divider()
                            .background(Color.platformSeparator)

                        // Local Relay Server Console
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Image(systemName: "terminal.fill")
                                    .font(.appSystem(size: 10, weight: .bold))
                                    .foregroundColor(.green)

                                Text("LOCAL RELAY SERVER CONSOLE")
                                    .font(.appSystem(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.secondary)

                                Spacer()

                                HStack(spacing: 5) {
                                    Circle().fill(Color.red.opacity(0.7)).frame(width: 7, height: 7)
                                    Circle().fill(Color.yellow.opacity(0.7)).frame(width: 7, height: 7)
                                    Circle().fill(Color.green.opacity(0.7)).frame(width: 7, height: 7)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.platformConsoleHeaderBackground)

                            Divider()
                                .background(Color.platformCardBorder)

                            LogsView(logStore: relayManager.logStore, hideHeader: true)
                                .frame(height: 200)
                        }
                        .background(Color.platformTertiaryGroupedBackground)
                    }
                } else if geometry.size.width > 680 {
                    let availableDashboardHeight = max(420, geometry.size.height - 300)
                    let preferredDashboardHeight = max(620, geometry.size.height * 0.56)
                    let dashboardHeight = min(preferredDashboardHeight, availableDashboardHeight)

                    VStack(spacing: 0) {
                        DashboardView(isSidebar: false)
                            .frame(height: dashboardHeight)
                            .clipped()
                            .environmentObject(relayManager)
                            .environmentObject(configService)
                            .environmentObject(nostrService)
                            .environmentObject(StatsService.shared)

                        Divider()
                            .background(Color.platformSeparator)

                        VStack(spacing: 0) {
                            desktopHeaderView

                            Divider()

                            ScrollView {
                                listContent

                                if !displayNotes.isEmpty || !displayMedia.isEmpty || !displayLikedNotes.isEmpty {
                                    Color.clear
                                        .frame(height: 1)
                                        .padding(.bottom, 20)
                                        .onAppear {
                                            if !nostrService.isFetching && (!displayNotes.isEmpty || !displayMedia.isEmpty) {
                                                loadMore()
                                            }
                                        }
                                        .id(nostrService.events.count)
                                }
                            }
                            .refreshable {
                                refreshAll()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .clipped()
                    }
                } else {
                    if showingRelayDashboard {
                        VStack(spacing: 0) {
                            HStack {
                                Text("Relay Dashboard")
                                    .font(.appSystem(size: 16, weight: .bold))
                                    .foregroundColor(.primary)
                                Spacer()
                                Button("Done") {
                                    showingRelayDashboard = false
                                }
                                .keyboardShortcut(.defaultAction)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .background(Color.platformConsoleHeaderBackground)

                            Divider()

                            DashboardView()
                                .environmentObject(relayManager)
                                .environmentObject(configService)
                                .environmentObject(nostrService)
                                .environmentObject(StatsService.shared)
                        }
                    } else {
                        compactViewContent(isNarrow: geometry.size.width < 500)
                    }
                }
            }
        }
        #endif
    }

    private var viewContentBase: some View {
        viewContentPlatform
        .onAppear {
            if relayManager.isRunning && !relayManager.isBooting {
                if !mediaOnly && feedService.followedPubkeys.isEmpty {
                    feedService.refresh()
                }
                // Only refresh if SceneDelegate didn't already handle reconnection
                // within the last 3 seconds (prevents double-reset race condition)
                let recentlyReconnected: Bool
                if let lastReconnect = nostrService.lastForegroundReconnectTime {
                    recentlyReconnected = Date().timeIntervalSince(lastReconnect) < 3.0
                } else {
                    recentlyReconnected = false
                }
                if nostrService.connectionStatus == "Disconnected" && !recentlyReconnected {
                    refreshAll()
                }
                initialLoad = true
                // Eagerly compute display data so tabs don't flash an empty state
                updateDisplayData()
            }
            if !mediaOnly && !hasEstablishedNotificationBaseline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    establishNotificationBaseline()
                }
            }
        }
        .onChange(of: relayManager.isBooting) { _, isBooting in
            if !isBooting && relayManager.isRunning {
                refreshAll()
                initialLoad = true
                triggerAutoMirrorIfEnabled()
                // Re-establish baseline after boot settles so initial events don't trigger highlights
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    establishNotificationBaseline()
                }
            }
        }
        .onChange(of: relayManager.isRunning) { _, isRunning in
            if isRunning && !relayManager.isBooting {
                refreshAll()
                initialLoad = true
            }
        }
        .onChange(of: selectedMedia) { _, _ in
            isCopied = false
        }
        #if os(iOS)
        // Present over the entire window (including the custom tab bar) on iOS.
        .fullScreenCover(isPresented: isPresentingViewer) {
            if let item = selectedMedia {
                mediaViewerContent(for: item)
            }
        }
        #else
        .overlay(fullScreenOverlay)
        #endif
    }

    private var viewContentWithHandlers: some View {
        viewContentBase
        .modifier(ViewerChangeHandlers(
            viewMode: viewMode,
            likesFilter: likesFilter,
            zapsFilter: zapsFilter,
            committedSearch: committedSearch,
            searchScope: searchScope,
            contentFilter: contentFilter,
            mediaSourceFilter: mediaSourceFilter,
            mediaLocationFilter: mediaLocationFilter,
            mediaTypeFilter: mediaTypeFilter,
            eventsCount: nostrService.events.count,
            noteMediaCount: nostrService.noteMedia.count,
            blacklistedNpubs: configService.config.blockedNpubsPerAccount[configService.config.activeAccountNpub.isEmpty ? configService.config.ownerNpub : configService.config.activeAccountNpub] ?? (configService.config.activeAccountNpub.isEmpty ? configService.config.blacklistedNpubs : []),
            activeAccountNpub: configService.config.activeAccountNpub,
            blossomCount: blossomCache.items.count,
            onResetAndUpdate: {
                maxDisplayedItems = 50
                notesHasLoadedOnce = false
                mediaHasLoadedOnce = false
                scheduleUpdateDisplayData()
            },
            onUpdate: { scheduleUpdateDisplayData() },
            onViewModeChange: { newMode in
                updateDisplayData()
                markTabViewed(newMode)
                if newMode == .likes {
                    fetchMissingLikedNotes()
                    updateLikesSettleState()
                }
                if newMode == .zaps {
                    fetchMoreZapReceipts()
                    fetchMissingZappedNotes()
                    updateZapsSettleState()
                }
            },
            onEventsChange: {
                scheduleUpdateDisplayData()
                checkForNewNotifications()
                if viewMode == .likes && likesFilter == .myLikes {
                    fetchMissingLikedNotes()
                }
                if viewMode == .zaps {
                    fetchMissingZappedNotes()
                }
            }
        ))
        .onChange(of: likesFilter) { _, _ in
            likesHasLoadedOnce = false
            likesInitialSettled = false
            updateLikesSettleState()
        }
        .onChange(of: zapsFilter) { _, _ in
            zapsHasLoadedOnce = false
            zapsInitialSettled = false
            updateZapsSettleState()
        }
        .onChange(of: configService.config.activeAccountNpub) { _, _ in
            notesHasLoadedOnce = false
            mediaHasLoadedOnce = false
            likesHasLoadedOnce = false
            likesInitialSettled = false
            zapsHasLoadedOnce = false
            zapsInitialSettled = false
            hasFetchedZapReceipts = false
            zapReceiptCache = [:]
            refreshAll()
        }
        .onChange(of: nostrService.isFetching) { _, _ in
            if viewMode == .likes { updateLikesSettleState() }
            if viewMode == .zaps { updateZapsSettleState() }
        }
        .onChange(of: relayManager.isBooting) { _, _ in
            if viewMode == .likes { updateLikesSettleState() }
            if viewMode == .zaps { updateZapsSettleState() }
        }
    }

    private var viewContent: some View {
        viewContentWithHandlers
        .onReceive(MirrorService.shared.$state) { newState in
            if newState == .complete {
                loadLocalMedia(force: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .feedInjectionComplete)) { _ in
            refreshAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaNotFoundChanged)) { _ in
            scheduleUpdateDisplayData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .blossomDirectoryChanged)) { _ in
            loadLocalMedia(force: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openRelayDashboard)) { _ in
            showingRelayDashboard = true
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayLikes)) { _ in
            guard !mediaOnly else { return }
            withAnimation(.easeInOut(duration: 0.15)) { viewMode = .likes }
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayNotes)) { _ in
            guard !mediaOnly else { return }
            withAnimation(.easeInOut(duration: 0.15)) { viewMode = .notes }
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayZaps)) { _ in
            guard !mediaOnly else { return }
            withAnimation(.easeInOut(duration: 0.15)) { viewMode = .zaps }
        }
        #endif
        .sheet(item: Binding<IdentifiableString?>(
            get: { showingProfilePubkey.map { IdentifiableString(id: $0) } },
            set: { showingProfilePubkey = $0?.id }
        )) { p in
            ProfileView(pubkey: p.id, onDismiss: { showingProfilePubkey = nil })
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { showingNoteId.map { IdentifiableString(id: $0) } },
            set: { showingNoteId = $0?.id }
        )) { noteId in
            NoteDetailViewWrapper(noteId: noteId.id, onDismiss: { showingNoteId = nil })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        #if os(iOS)
        .sheet(isPresented: $showingRelayDashboard) {
            NavigationView {
                DashboardView()
                    .environmentObject(relayManager)
                    .environmentObject(configService)
                    .environmentObject(nostrService)
                    .environmentObject(StatsService.shared)
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingRelayDashboard = false }
                        }
                    }
            }
        }
        #endif
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.image, .movie],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                handleUploadFileURLs(urls)
            case .failure(let error):
                print("Failed to select files: \(error)")
            }
        }
        .photosPicker(
            isPresented: $showingPhotoPicker,
            selection: $selectedUploadItems,
            matching: photosPickerFilter
        )
        .onChange(of: selectedUploadItems) { _, items in
            if !items.isEmpty {
                handleUploadSelectedItems(items)
                showingPhotoPicker = false
            }
        }
        .sheet(isPresented: $showingBlossomMediaList) {
            BlossomDashboardView()
                .environmentObject(configService)
                .environmentObject(nostrService)
        }
    }

    @ViewBuilder
    private func compactViewContent(isNarrow: Bool) -> some View {
        VStack(spacing: 0) {
            headerView(isNarrow: isNarrow)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    listContent

                    if !displayNotes.isEmpty || !displayMedia.isEmpty || !displayLikedNotes.isEmpty {
                        Color.clear
                            .frame(height: 1)
                            .padding(.bottom, 20)
                            .onAppear {
                                if !nostrService.isFetching && (!displayNotes.isEmpty || !displayMedia.isEmpty) {
                                    loadMore()
                                }
                            }
                            .id(nostrService.events.count)
                    }
                }
                .tabBarBottomPadding()
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                refreshAll()
            }
            .scrollDirectionTracking(feedService: feedService)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if os(iOS)
        .overlay(alignment: .bottomTrailing) {
            if !feedService.feedScrollingDown {
                if viewMode == .media {
                    // Blossom button for Media mode
                    Button(action: { showingBlossomMediaList = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "camera.macro")
                                .font(.appSystem(size: 15, weight: .bold))
                            Text("Blossom")
                                .font(.appSystem(size: 14, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .frame(height: 48)
                        .padding(.horizontal, 18)
                        .background(
                            Capsule()
                                .fill(Color.havenPurple)
                                .shadow(color: Color.havenPurple.opacity(0.35), radius: 8, x: 0, y: 4)
                        )
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 90)
                    .hoverEffect(.lift)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                } else {
                    // Relay button for other modes
                    Button(action: { showingRelayDashboard = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.appSystem(size: 15, weight: .bold))
                            Text("Relay")
                                .font(.appSystem(size: 14, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .frame(height: 48)
                        .padding(.horizontal, 18)
                        .background(
                            Capsule()
                                .fill(statusColor)
                                .shadow(color: statusColor.opacity(0.35), radius: 8, x: 0, y: 4)
                        )
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 90)
                    .hoverEffect(.lift)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: feedService.feedScrollingDown)
        #endif
    }

    @ViewBuilder
    private var desktopHeaderView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                modeView
                
                Spacer()
                
                if viewMode == .notes {
                    filterView
                } else if viewMode == .likes {
                    likesFilterView
                } else if viewMode == .zaps {
                    zapsFilterView
                } else if viewMode == .media {
                    uploadButton
                }

                if viewMode != .media {
                    compactToggleButton
                }
            }

        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color.platformSecondaryGroupedBackground)
    }

    private var uploadButton: some View {
        Menu {
            Button(action: {
                photosPickerFilter = .images
                showingPhotoPicker = true
            }) {
                Label("Photos", systemImage: "photo")
            }
            Button(action: {
                photosPickerFilter = .videos
                showingPhotoPicker = true
            }) {
                Label("Videos", systemImage: "video")
            }
            Button(action: { showingFileImporter = true }) {
                Label("Files", systemImage: "folder")
            }
            Button(action: handlePasteFromClipboard) {
                Label("Magic Paste", systemImage: "wand.and.stars")
            }
            .disabled(isPastingContent)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.appSystem(size: 11, weight: .bold))
                Text("Upload")
                    .font(.appSystem(size: 12, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                LinearGradient(
                    colors: [Color.havenPurple, Color.havenPurpleLight],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .cornerRadius(12)
            .shadow(color: Color.havenPurple.opacity(0.3), radius: 4, x: 0, y: 2)
        }
        .menuStyle(.automatic)
    }


    private func toggleMediaTypeFilter(_ filter: MediaTypeFilter) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if mediaTypeFilter.count == MediaTypeFilter.allCases.count {
                mediaTypeFilter = [filter]
            } else if mediaTypeFilter.contains(filter) {
                if mediaTypeFilter.count > 1 {
                    mediaTypeFilter.remove(filter)
                }
            } else {
                mediaTypeFilter.insert(filter)
            }
        }
    }

    private func selectAllMediaTypes() {
        withAnimation(.easeInOut(duration: 0.15)) {
            mediaTypeFilter = Set(MediaTypeFilter.allCases)
        }
    }

    private func selectLocationFilter(_ filter: MediaLocationFilter) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if mediaLocationFilter == filter {
                mediaLocationFilter = .all
            } else {
                mediaLocationFilter = filter
            }
        }
    }



    private var notesButton: some View {
        ModeButton(title: "Notes", icon: "doc.text", isSelected: viewMode == .notes, hasNotification: hasNewNotes) {
            withAnimation(.easeInOut(duration: 0.15)) { viewMode = .notes }
        }
    }

    private var mediaButton: some View {
        ModeButton(title: "Media", icon: "photo.on.rectangle", isSelected: viewMode == .media) {
            withAnimation(.easeInOut(duration: 0.15)) { viewMode = .media }
            if relayManager.isRunning && !relayManager.isBooting {
                loadLocalMedia()
            }
        }
    }

    private var likesButton: some View {
        ModeButton(title: "Likes", icon: "heart.fill", isSelected: viewMode == .likes, hasNotification: hasNewLikes) {
            withAnimation(.easeInOut(duration: 0.15)) { viewMode = .likes }
            fetchMissingLikedNotes()
        }
    }

    private var zapsButton: some View {
        ModeButton(title: "Zaps", icon: "bolt.fill", isSelected: viewMode == .zaps, hasNotification: hasNewZaps) {
            withAnimation(.easeInOut(duration: 0.15)) { viewMode = .zaps }
        }
    }

    private var modeView: some View {
        HStack(spacing: 4) {
            notesButton
            likesButton
            zapsButton
            #if os(iOS)
            // Add compact toggle on mobile
            if UIDevice.current.userInterfaceIdiom == .phone {
                compactToggleButton
            }
            #endif
        }
        .padding(4)
        .background(Color(red: 0.15, green: 0.15, blue: 0.2))
        .cornerRadius(20)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.8))
    }

    private var compactToggleButton: some View {
        ModeButton(
            title: "Compact",
            icon: "rectangle.compress.vertical",
            isSelected: noteLayoutMode == .compact
        ) {
            withAnimation(.easeInOut(duration: 0.15)) {
                noteLayoutMode = noteLayoutMode == .compact ? .expanded : .compact
            }
        }
    }
    
    private var filterView: some View {
        HStack(spacing: 2) {
            FilterButton(title: "All", color: .secondary, isSelected: contentFilter == .all) {
                contentFilter = .all
            }
            FilterButton(title: "My Notes", color: .havenPurple, isSelected: contentFilter == .mine) {
                contentFilter = .mine
            }
            FilterButton(title: "Tagged", color: Color(red: 0.2, green: 0.8, blue: 0.6), isSelected: contentFilter == .tagged) {
                contentFilter = .tagged
            }
            FilterButton(title: "Whitelisted", color: Color(red: 0.2, green: 0.8, blue: 0.6).opacity(0.7), isSelected: contentFilter == .whitelist) {
                contentFilter = .whitelist
            }
        }
        .padding(4)
        .background(Color(red: 0.15, green: 0.15, blue: 0.2))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.8))
    }
    
    private var sourceFilterView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle")
                    .font(.appSystem(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.trailing, 2)

                ForEach(MediaTypeFilter.allCases, id: \.self) { typeFilter in
                    FilterButton(
                        title: typeFilter.rawValue,
                        color: .havenPurple,
                        isSelected: mediaTypeFilter.contains(typeFilter)
                    ) {
                        if mediaTypeFilter.contains(typeFilter) {
                            mediaTypeFilter.remove(typeFilter)
                        } else {
                            mediaTypeFilter.insert(typeFilter)
                        }
                    }
                }
            }
        }
    }
    
    private var likesFilterView: some View {
        HStack(spacing: 2) {
            FilterButton(title: "My Notes", icon: "person.fill", color: .havenPurple, isSelected: likesFilter == .onMyNotes) {
                likesFilter = .onMyNotes
            }
            FilterButton(title: "Tagged", icon: "at", color: .havenPurple, isSelected: likesFilter == .onTagged) {
                likesFilter = .onTagged
            }
            FilterButton(title: "Whitelisted", icon: "checkmark.seal.fill", color: .havenPurple, isSelected: likesFilter == .onWhitelisted) {
                likesFilter = .onWhitelisted
            }
            FilterButton(title: "My Likes", icon: "heart", color: .pink, isSelected: likesFilter == .myLikes) {
                likesFilter = .myLikes
            }
        }
        .padding(4)
        .background(Color(red: 0.15, green: 0.15, blue: 0.2))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.8))
    }

    private var zapsFilterView: some View {
        HStack(spacing: 2) {
            FilterButton(title: "My Notes", icon: "person.fill", color: .havenPurple, isSelected: zapsFilter == .onMyNotes) {
                zapsFilter = .onMyNotes
            }
            FilterButton(title: "Tagged", icon: "at", color: .havenPurple, isSelected: zapsFilter == .onTagged) {
                zapsFilter = .onTagged
            }
            FilterButton(title: "Whitelisted", icon: "checkmark.seal.fill", color: .havenPurple, isSelected: zapsFilter == .onWhitelisted) {
                zapsFilter = .onWhitelisted
            }
            FilterButton(title: "My Zaps", icon: "bolt", color: .yellow, isSelected: zapsFilter == .myZaps) {
                zapsFilter = .myZaps
            }
        }
        .padding(4)
        .background(Color(red: 0.15, green: 0.15, blue: 0.2))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.8))
    }

    private var likesList: some View {
        let isFetching = nostrService.isFetching || relayManager.isBooting
        // Keep showing the loading view until we've either populated content
        // (likesHasLoadedOnce) or settled into a confirmed-empty state.
        let showLoading = displayLikedNotes.isEmpty
            && !likesHasLoadedOnce
            && (isFetching || !likesInitialSettled)
        return Group {
            if showLoading {
                VStack(spacing: 32) {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)
                        VStack(spacing: 8) {
                            Text("Loading likes...")
                                .font(.appSystem(size: 18, weight: .bold, design: .default))
                                .tracking(0.3)
                            Text("This may take a moment")
                                .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.6))
                                .tracking(0.5)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.platformWindowBackground)
            } else if displayLikedNotes.isEmpty {
                VStack(spacing: 24) {
                    Image(systemName: likesFilter != .myLikes ? "heart.slash" : "heart")
                        .font(.appSystem(size: 48, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [.red, .pink]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    VStack(spacing: 8) {
                        Text(likesFilter != .myLikes ? "No reactions yet" : "No liked posts")
                            .font(.appSystem(size: 18, weight: .bold, design: .default))
                            .tracking(0.2)
                        Text(likesFilter != .myLikes ? "Reactions on these notes will appear here" : "Posts you've liked will appear here")
                            .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.platformWindowBackground)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(displayLikedNotes) { event in
                        VStack(alignment: .leading, spacing: 0) {
                            // Show who liked this post (all incoming reaction modes)
                            if likesFilter != .myLikes, let reactors = reactionMap[event.id], !reactors.isEmpty {
                                LikedByRow(reactors: reactors, latestDate: latestReactionDates[event.id])
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 6)
                            }

                            #if os(iOS)
                            NavigationLink(destination: NoteDetailView(note: FeedNote(
                                id: event.id,
                                pubkey: event.pubkey,
                                content: event.content,
                                createdAt: event.createdAtDate,
                                tags: event.tags,
                                kind: event.kind
                            ))) {
                                NoteRow(event: event, truncate: true, layoutMode: noteLayoutMode)
                                    .padding(.horizontal, 16)
                                    .onAppear {
                                        if event.id == displayLikedNotes.last?.id {
                                            loadMoreItems()
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            #else
                            NoteRow(event: event, truncate: true, layoutMode: noteLayoutMode)
                                .padding(.horizontal, 16)
                                .onAppear {
                                    if event.id == displayLikedNotes.last?.id {
                                        loadMoreItems()
                                    }
                                }
                            #endif
                        }
                    }
                }
                .environment(\.openURL, OpenURLAction { url in
                    if url.scheme == "nostr" {
                        let id = url.absoluteString.replacingOccurrences(of: "nostr:", with: "")
                        if id.hasPrefix("npub1") || id.hasPrefix("nprofile1") {
                            self.showingProfilePubkey = id
                            return .handled
                        } else if id.hasPrefix("note1") || id.hasPrefix("nevent1") || id.hasPrefix("naddr1") {
                            self.showingNoteId = id
                            return .handled
                        }
                    }
                    return .systemAction
                })
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var zapsList: some View {
        let isFetching = nostrService.isFetching || relayManager.isBooting
        let showLoading = displayZappedNotes.isEmpty
            && !zapsHasLoadedOnce
            && (isFetching || !zapsInitialSettled)
        return Group {
            if showLoading {
                VStack(spacing: 32) {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)
                        VStack(spacing: 8) {
                            Text("Loading zaps...")
                                .font(.appSystem(size: 18, weight: .bold, design: .default))
                                .tracking(0.3)
                            Text("This may take a moment")
                                .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.6))
                                .tracking(0.5)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.platformWindowBackground)
            } else if displayZappedNotes.isEmpty {
                VStack(spacing: 24) {
                    Image(systemName: zapsFilter != .myZaps ? "bolt.slash" : "bolt")
                        .font(.appSystem(size: 48, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [.orange, .yellow]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    VStack(spacing: 8) {
                        Text(zapsFilter != .myZaps ? "No zaps yet" : "No zapped posts")
                            .font(.appSystem(size: 18, weight: .bold, design: .default))
                            .tracking(0.2)
                        Text(zapsFilter != .myZaps ? "Zaps on these notes will appear here" : "Posts you've zapped will appear here")
                            .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.platformWindowBackground)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(displayZappedNotes) { event in
                        VStack(alignment: .leading, spacing: 0) {
                            if zapsFilter != .myZaps, let zappers = zapMap[event.id], !zappers.isEmpty {
                                ZappedByRow(zappers: zappers)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 6)
                            }

                            #if os(iOS)
                            NavigationLink(destination: NoteDetailView(note: FeedNote(
                                id: event.id,
                                pubkey: event.pubkey,
                                content: event.content,
                                createdAt: event.createdAtDate,
                                tags: event.tags,
                                kind: event.kind
                            ))) {
                                NoteRow(event: event, truncate: true, layoutMode: noteLayoutMode)
                                    .padding(.horizontal, 16)
                                    .onAppear {
                                        if event.id == displayZappedNotes.last?.id {
                                            loadMoreItems()
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            #else
                            NoteRow(event: event, truncate: true, layoutMode: noteLayoutMode)
                                .padding(.horizontal, 16)
                                .onAppear {
                                    if event.id == displayZappedNotes.last?.id {
                                        loadMoreItems()
                                    }
                                }
                            #endif
                        }
                    }
                }
                .environment(\.openURL, OpenURLAction { url in
                    if url.scheme == "nostr" {
                        let id = url.absoluteString.replacingOccurrences(of: "nostr:", with: "")
                        if id.hasPrefix("npub1") || id.hasPrefix("nprofile1") {
                            self.showingProfilePubkey = id
                            return .handled
                        } else if id.hasPrefix("note1") || id.hasPrefix("nevent1") || id.hasPrefix("naddr1") {
                            self.showingNoteId = id
                            return .handled
                        }
                    }
                    return .systemAction
                })
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var profileSearchResults: some View {
        if displayProfileResults.isEmpty {
            VStack(spacing: 24) {
                Image(systemName: "person.2.slash")
                    .font(.appSystem(size: 48, weight: .thin))
                    .foregroundStyle(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.havenPurple, Color.havenPurple.opacity(0.5)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                VStack(spacing: 8) {
                    Text("No profiles found")
                        .font(.appSystem(size: 18, weight: .bold))
                        .tracking(0.2)
                    Text("Try a different search term")
                        .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                        .tracking(0.3)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(displayProfileResults) { profile in
                    ProfileResultRow(profile: profile)
                        .onTapGesture {
                            showingProfilePubkey = profile.pubkey
                        }
                    Divider()
                        .background(Color(red: 0.2, green: 0.2, blue: 0.25))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var notesList: some View {
        let isLoading = nostrService.isFetching || relayManager.isBooting || !notesHasLoadedOnce
        return Group {
            if displayNotes.isEmpty && isLoading {
                VStack(spacing: 32) {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)

                        VStack(spacing: 8) {
                            Text(relayManager.isBooting ? relayManager.bootStatusMessage.isEmpty ? "Starting relay..." : relayManager.bootStatusMessage : "Loading notes...")
                                .font(.appSystem(size: 18, weight: .bold, design: .default))
                                .tracking(0.3)
                            Text("This may take a moment")
                                .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.6))
                                .tracking(0.5)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.platformWindowBackground)
            } else if displayNotes.isEmpty {
                VStack(spacing: 24) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.appSystem(size: 48, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    VStack(spacing: 8) {
                        Text("No notes found")
                            .font(.appSystem(size: 18, weight: .bold, design: .default))
                            .tracking(0.2)

                        Text("Try changing your filter settings")
                            .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.platformWindowBackground)
            } else {
                let whitelisted = configService.whitelistedHexPubkeys
                let owner = nostrService.activeHexPubkey
                LazyVStack(spacing: 12) {
                    ForEach(displayNotes) { event in
                        let showEngagement = event.pubkey == owner || whitelisted.contains(event.pubkey)
                        #if os(iOS)
                        NavigationLink(destination: NoteDetailView(note: FeedNote(
                            id: event.id,
                            pubkey: event.pubkey,
                            content: event.content,
                            createdAt: event.createdAtDate,
                            tags: event.tags,
                            kind: event.kind
                        ))) {
                            NoteRow(
                                event: event,
                                layoutMode: noteLayoutMode,
                                reactors: showEngagement ? reactionMap[event.id] : nil,
                                latestReactionDate: showEngagement ? latestReactionDates[event.id] : nil,
                                zappers: showEngagement ? zapMap[event.id] : nil,
                                reposterPubkeys: showEngagement ? repostMap[event.id] : nil,
                                quoterPubkeys: showEngagement ? quoteMap[event.id] : nil
                            )
                        }
                        .buttonStyle(.plain)
                        #else
                        NoteRow(
                            event: event,
                            layoutMode: noteLayoutMode,
                            reactors: showEngagement ? reactionMap[event.id] : nil,
                            latestReactionDate: showEngagement ? latestReactionDates[event.id] : nil,
                            zappers: showEngagement ? zapMap[event.id] : nil,
                            reposterPubkeys: showEngagement ? repostMap[event.id] : nil,
                            quoterPubkeys: showEngagement ? quoteMap[event.id] : nil
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            self.showingNoteId = event.id
                        }
                        #endif
                    }
                }
                .environment(\.openURL, OpenURLAction { url in
                    if url.scheme == "nostr" {
                        let id = url.absoluteString.replacingOccurrences(of: "nostr:", with: "")
                        if id.hasPrefix("npub1") || id.hasPrefix("nprofile1") {
                            self.showingProfilePubkey = id
                            return .handled
                        } else if id.hasPrefix("note1") || id.hasPrefix("nevent1") {
                            self.showingNoteId = id
                            return .handled
                        }
                    }
                    return .systemAction
                })
                .frame(maxWidth: .infinity)
            }
        }
    }
    
    private var mediaGrid: some View {
        let items = displayMedia
        let isLoading = blossomCache.isScanning || nostrService.isFetching || !mediaHasLoadedOnce
        return Group {
            if items.isEmpty && isLoading {
                VStack(spacing: 32) {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)

                        VStack(spacing: 8) {
                            Text("Loading media...")
                                .font(.appSystem(size: 18, weight: .bold, design: .default))
                                .tracking(0.3)
                            Text("Scanning for uploads")
                                .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.6))
                                .tracking(0.5)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.platformWindowBackground)
            } else if items.isEmpty {
                VStack(spacing: 24) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.appSystem(size: 48, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    VStack(spacing: 8) {
                        Text("No media found")
                            .font(.appSystem(size: 18, weight: .bold, design: .default))
                            .tracking(0.2)

                        Text("Try changing your filter settings")
                            .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.platformWindowBackground)
            } else {
                if mediaLayoutMode == .grid {
                    #if os(macOS)
                    let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
                    #else
                    let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
                    #endif

                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(items) { item in
                            MediaGridItem(
                                item: item,
                                onDeleteFromMirrors: { deleteMediaFromMirrors(item: $0) },
                                onDeleteEverywhere: { deleteMediaEverywhere(item: $0) },
                                onMirrorComplete: { loadLocalMedia(force: true) }
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) { selectedMedia = item }
                            }
                            .onAppear {
                                if item.id == items.last?.id {
                                    loadMoreItems()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(items) { item in
                            MediaListItem(
                                item: item,
                                onDeleteFromMirrors: { deleteMediaFromMirrors(item: $0) },
                                onDeleteEverywhere: { deleteMediaEverywhere(item: $0) },
                                onMirrorComplete: { loadLocalMedia(force: true) }
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) { selectedMedia = item }
                            }
                            .onAppear {
                                if item.id == items.last?.id {
                                    loadMoreItems()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
    }
    
    @ViewBuilder
    private func mediaViewerContent(for item: MediaItem) -> some View {
        ZStack {
            Color.black.opacity(0.9 * max(0, 1.0 - (abs(dragOffset.height) / 300.0)))
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedMedia = nil
                        dragOffset = .zero
                    }
                }

            VStack {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        if configService.hasExternalShareURL(for: item.url) {
                            Button(action: {
                                PlatformClipboard.copy(item.shareURL(with: configService).absoluteString)
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                    isCopied = true
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        isCopied = false
                                    }
                                }
                            }) {
                                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                    .font(.appSystem(size: 16, weight: .semibold))
                                    .foregroundColor(isCopied ? .green : .white)
                                    .padding(10)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(8)
                                    .scaleEffect(isCopied ? 1.15 : 1.0)
                            }
                            .buttonStyle(.plain)
                        }

                        #if os(iOS)
                        if item.type == .image || item.type == .video {
                            Button(action: {
                                saveMediaToPhotos(item: item)
                            }) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.appSystem(size: 16, weight: .semibold))
                                    .padding(10)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                        #endif

                        Menu {
                            Button(role: .destructive, action: {
                                deleteMediaFromMirrors(item: item)
                            }) {
                                Label("Delete from mirrors", systemImage: "trash")
                            }
                            Button(role: .destructive, action: {
                                deleteMediaEverywhere(item: item)
                            }) {
                                Label("Delete everywhere", systemImage: "trash.fill")
                            }
                        } label: {
                            Image(systemName: "trash")
                                .font(.appSystem(size: 16, weight: .semibold))
                                .padding(10)
                                .background(Color.white.opacity(0.1))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)

                        SourceIndicatorView(
                            url: item.url,
                            onMirrorComplete: {
                                loadLocalMedia(force: true)
                            }
                        )

                        if let noteId = findNoteId(for: item) {
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedMedia = nil
                                    dragOffset = .zero
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showingNoteId = noteId
                                }
                            }) {
                                Image(systemName: "doc.text")
                                    .font(.appSystem(size: 16, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(10)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer()

                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedMedia = nil
                                dragOffset = .zero
                            }
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.appTitle)
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                    #if os(iOS)
                    if let message = saveToPhotosMessage {
                        Text(message)
                            .font(.appCaption)
                            .foregroundColor(message.contains("Saved") ? .green : .red)
                            .transition(.opacity)
                    }
                    #endif
                    if isCopied {
                        Text("Link copied to clipboard")
                            .font(.appCaption)
                            .foregroundColor(.green)
                            .transition(.opacity)
                    }
                }
                .padding()
                .opacity(max(0, 1.0 - (abs(dragOffset.height) / 100.0)))

                Spacer()

                TabView(selection: $selectedMedia) {
                    ForEach(displayMedia) { mediaItem in
                        ViewerViewMediaItem(mediaItem: mediaItem)
                            .tag(mediaItem as MediaItem?)
                    }
                }
                .mediaTabViewStyleCompat()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: dragOffset.height)
                .scaleEffect(max(0.8, 1.0 - (abs(dragOffset.height) / 1000.0)))
                .gesture(
                    DragGesture()
                        .onChanged { gesture in
                            // Only capture vertical drags to not conflict with horizontal swiping
                            if abs(gesture.translation.height) > abs(gesture.translation.width) || dragOffset.height != 0 {
                                dragOffset = CGSize(width: 0, height: gesture.translation.height)
                            }
                        }
                        .onEnded { gesture in
                            if abs(dragOffset.height) > 120 {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    selectedMedia = nil
                                    dragOffset = .zero
                                }
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                    dragOffset = .zero
                                }
                            }
                        }
                )

                Spacer()

                Text(configService.externalShareURL(for: item.url).absoluteString)
                    .font(.appCaption.monospaced())
                    .foregroundColor(.secondary)
                    .padding(.bottom)
                    .opacity(max(0, 1.0 - (abs(dragOffset.height) / 100.0)))
            }
        }
        .transition(.opacity)
        #if os(iOS)
        .background(ClearFullScreenBackground())
        #endif
        #if os(macOS)
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
        #endif
    }

    /// macOS path: traditional in-window overlay.
    @ViewBuilder
    private var fullScreenOverlay: some View {
        if let item = selectedMedia {
            mediaViewerContent(for: item)
        }
    }

    /// Binding wrapping `selectedMedia` for `.fullScreenCover(isPresented:)`.
    /// Resets the drag offset when dismissed so the next presentation isn't shifted.
    private var isPresentingViewer: Binding<Bool> {
        Binding(
            get: { selectedMedia != nil },
            set: { presenting in
                if !presenting {
                    selectedMedia = nil
                    dragOffset = .zero
                }
            }
        )
    }

    /// Find the Nostr event ID for a media item by matching its URL or blossom hash against stored events.
    private func findNoteId(for item: MediaItem) -> String? {
        let mediaURL = item.url.absoluteString
        // Try exact URL match first
        if let event = nostrService.events.first(where: { $0.content.contains(mediaURL) }) {
            return event.id
        }
        // For blossom URLs the displayed URL may differ from the original;
        // fall back to matching the SHA256 hash embedded in the URL path.
        let hash = item.url.lastPathComponent
        if hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) {
            return nostrService.events.first(where: { $0.content.contains(hash) })?.id
        }
        return nil
    }

    private func navigateMedia(direction: Int) {
        guard let current = selectedMedia,
              let index = displayMedia.firstIndex(where: { $0.id == current.id }) else { return }
        let newIndex = index + direction
        guard displayMedia.indices.contains(newIndex) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { selectedMedia = displayMedia[newIndex] }
    }

    #if os(macOS)
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard selectedMedia != nil else { return event }
            switch event.keyCode {
            case 123: // left arrow — previous item in grid
                navigateMedia(direction: -1)
                return nil
            case 124: // right arrow — next item in grid
                navigateMedia(direction: 1)
                return nil
            case 53: // escape
                withAnimation(.easeInOut(duration: 0.2)) { selectedMedia = nil }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
    #endif

    func refreshAll() {
        // Only proceed if relay is actually ready
        guard relayManager.isRunning && !relayManager.isBooting else {
            #if DEBUG
            print("ViewerView: Skipping refresh - relay not ready")
            #endif
            return
        }

        // Debounce: cancel any pending refresh and wait 0.5s before executing.
        // Multiple rapid lifecycle events (onAppear, onChange isBooting, onChange isRunning)
        // can fire within milliseconds of each other — this coalesces them into one refresh.
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            guard !Task.isCancelled else { return }
            performRefresh()
        }
    }

    private func performRefresh() {
        nostrService.resetConnections()
        // Use the centralized nostrURL which handles local vs remote correctly
        var urls = [configService.config.nostrURL, configService.config.nostrURL + "/inbox"].compactMap { URL(string: $0) }
        guard !urls.isEmpty else { return }

        // Also query the Mac relay for tagged notes the local relay may
        // not have (e.g. due to shorter WoT depth or notes missed while suspended).
        let macURL = configService.config.macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !macURL.isEmpty {
            if let macRelay = URL(string: macURL) { urls.append(macRelay) }
            if let macInbox = URL(string: macURL + "/inbox") { urls.append(macInbox) }
        }

        var authorsSet = Set<String>()
        if let ownerHex = Bech32.decode(configService.config.ownerNpub)?.hexString {
            authorsSet.insert(ownerHex)
        }
        for pk in configService.whitelistedHexPubkeys { authorsSet.insert(pk) }
        let authors = Array(authorsSet)

        nostrService.fetchNotes(from: urls, authors: authors)
        loadLocalMedia()
    }
    
    /// Fetch notes referenced by the owner's likes that aren't already in the events array.
    private func fetchMissingLikedNotes() {
        let owner = nostrService.activeHexPubkey
        guard !owner.isEmpty else { return }

        let likedNoteIds = Set(nostrService.events.filter { $0.kind == 7 && $0.pubkey == owner }.compactMap { event in
            event.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1]
        })
        let existingIds = Set(nostrService.events.map { $0.id })
        let missingIds = Array(likedNoteIds.subtracting(existingIds).subtracting(requestedMissingIds))

        guard !missingIds.isEmpty else { return }
        for id in missingIds { requestedMissingIds.insert(id) }

        #if DEBUG
        print("ViewerView: Fetching \(missingIds.count) missing liked notes")
        #endif

        var urls = [configService.config.nostrURL].compactMap { URL(string: $0) }
        // Also try external relays for notes not on the local relay
        let externalStrs = configService.config.activeFeedRelays.isEmpty ? [
            "wss://relay.damus.io",
            "wss://relay.primal.net",
            "wss://nos.lol",
        ] : configService.config.activeFeedRelays
        urls.append(contentsOf: externalStrs.compactMap { URL(string: $0) })

        nostrService.fetchNotesByIds(missingIds, from: urls)
    }

    /// Fetch a larger set of zap receipts from the relay when entering zaps mode.
    @State private var hasFetchedZapReceipts = false
    private func fetchMoreZapReceipts() {
        guard !hasFetchedZapReceipts else { return }
        hasFetchedZapReceipts = true

        var urls = [configService.config.nostrURL, configService.config.nostrURL + "/inbox"].compactMap { URL(string: $0) }
        guard !urls.isEmpty else { return }
        let macURL = configService.config.macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !macURL.isEmpty, let macRelay = URL(string: macURL) {
            urls.append(macRelay)
        }

        #if DEBUG
        print("ViewerView: Fetching extended zap receipts history")
        #endif
        nostrService.fetchZapReceipts(from: urls, limit: 1000)
    }

    /// Fetch notes referenced by zap receipts that aren't already in the events array.
    private func fetchMissingZappedNotes() {
        let zapReceipts = nostrService.events.filter { $0.kind == 9735 }
        guard !zapReceipts.isEmpty else { return }

        var targetNoteIds = Set<String>()
        for receipt in zapReceipts {
            if let cached = zapReceiptCache[receipt.id] {
                if let noteId = cached.targetNoteId { targetNoteIds.insert(noteId) }
            } else if let targetId = receipt.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] {
                targetNoteIds.insert(targetId)
            }
        }

        let existingIds = Set(nostrService.events.map { $0.id })
        let missingIds = Array(targetNoteIds.subtracting(existingIds).subtracting(requestedMissingZapNoteIds))

        guard !missingIds.isEmpty else { return }
        for id in missingIds { requestedMissingZapNoteIds.insert(id) }

        #if DEBUG
        print("ViewerView: Fetching \(missingIds.count) missing zapped notes")
        #endif

        var urls = [configService.config.nostrURL].compactMap { URL(string: $0) }
        let externalStrs = configService.config.activeFeedRelays.isEmpty ? [
            "wss://relay.damus.io",
            "wss://relay.primal.net",
            "wss://nos.lol",
        ] : configService.config.activeFeedRelays
        urls.append(contentsOf: externalStrs.compactMap { URL(string: $0) })

        nostrService.fetchNotesByIds(missingIds, from: urls)
    }

    func loadMoreItems() {
        let totalCount: Int
        switch viewMode {
        case .notes: totalCount = nostrService.events.count
        case .media: totalCount = blossomCache.items.count
        case .likes: totalCount = nostrService.events.count
        case .zaps: totalCount = nostrService.events.count
        }
        if maxDisplayedItems < totalCount {
            maxDisplayedItems += 50
            scheduleUpdateDisplayData()
        }
    }
    
    func loadMore() {
        guard !nostrService.isFetching else { return }
        
        // Get the oldest timestamp from events
        guard let oldestTimestamp = nostrService.events.last?.created_at else { return }
        
        // Request events strictly older than the last one we have
        #if DEBUG
        print("ViewerView: Requesting older events until: \(oldestTimestamp - 1)")
        #endif
        var urls = [configService.config.nostrURL, configService.config.nostrURL + "/inbox"].compactMap { URL(string: $0) }
        guard !urls.isEmpty else { return }
        let macURL = configService.config.macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !macURL.isEmpty, let macInbox = URL(string: macURL + "/inbox") {
            urls.append(macInbox)
        }

        var authorsSet = Set<String>()
        if let ownerHex = Bech32.decode(configService.config.ownerNpub)?.hexString {
            authorsSet.insert(ownerHex)
        }
        for pk in configService.whitelistedHexPubkeys { authorsSet.insert(pk) }
        let authors = Array(authorsSet)
        
        nostrService.fetchNotes(from: urls, until: oldestTimestamp - 1, authors: authors)
    }
    
    private func triggerAutoMirrorIfEnabled() {
        guard configService.config.autoMirrorMedia else { return }
        MirrorService.shared.runMirror(configService: configService, nostrService: nostrService)
    }

    #if os(iOS)
    private func saveMediaToPhotos(item: MediaItem) {
        saveToPhotosMessage = nil

        Task {
            // Request photo library permission
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                await MainActor.run {
                    saveToPhotosMessage = "Photo library access denied"
                }
                return
            }

            // Download media data
            let session = URLSession(configuration: .default, delegate: LocalhostTrustDelegate(), delegateQueue: nil)
            do {
                let (data, _) = try await session.data(from: item.url)

                if item.type == .video {
                    // Videos need a temp file
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
                    try data.write(to: tempURL)
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: tempURL, options: nil)
                    }
                    try? FileManager.default.removeItem(at: tempURL)
                } else {
                    try await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()
                        let options = PHAssetResourceCreationOptions()
                        request.addResource(with: .photo, data: data, options: options)
                    }
                }

                await MainActor.run {
                    withAnimation { saveToPhotosMessage = "Saved to Photos" }
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        await MainActor.run { withAnimation { saveToPhotosMessage = nil } }
                    }
                }
            } catch {
                await MainActor.run {
                    saveToPhotosMessage = "Failed to save"
                }
                print("Save to Photos error: \(error.localizedDescription)")
            }
        }
    }
    #endif

    func loadLocalMedia(force: Bool = false) {
        let cache = blossomCache

        // Start filesystem watcher so external uploads (e.g. phone → Mac relay) trigger a rescan
        let blossomDir = configService.relayDataDir.appendingPathComponent(configService.config.blossomPath)
        cache.startWatchingIfNeeded(directory: blossomDir)

        // Skip rescan if cache is fresh and this isn't a forced reload (e.g. after upload/delete)
        if !force && cache.isFresh() { return }

        // Concurrency guard
        if cache.isScanning { return }

        // Only load if relay is ready
        guard relayManager.isRunning && !relayManager.isBooting else {
            #if DEBUG
            print("ViewerView: Skipping media load - relay not ready")
            #endif
            cache.items = []
            return
        }

        cache.isScanning = true

        // Use a Task for non-blocking I/O
        Task {
            let relayDataDir = configService.relayDataDir
            let blossomPath = configService.config.blossomPath
            let ownerHex = nostrService.activeHexPubkey
            let webURL = configService.config.webURL
            let rpm = relayManager

            let result = await Task.detached(priority: .background) { () -> [MediaItem] in
                let blossomDir = relayDataDir.appendingPathComponent(blossomPath)
                if !FileManager.default.fileExists(atPath: blossomDir.path) {
                    try? FileManager.default.createDirectory(at: blossomDir, withIntermediateDirectories: true)
                    return []
                }

                guard let fileURLs = try? FileManager.default.contentsOfDirectory(at: blossomDir, includingPropertiesForKeys: [.creationDateKey]) else {
                    return []
                }

                return fileURLs.compactMap { fileURL -> MediaItem? in
                    let filename = fileURL.lastPathComponent
                    if filename.starts(with: ".") || filename == "LOCK" { return nil }
                    guard let serveURL = URL(string: "\(webURL)/\(filename)") else { return nil }

                    let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                    let date = (attributes?[.modificationDate] as? Date) ?? (attributes?[.creationDate] as? Date) ?? Date()

                    // Same detection pipeline as blossom export: proof (bytes) + claim (relay) → resolve
                    // PERFORMANCE: We skip `fetchMimeFromRelay` here because doing 9000 awaits starves the UI thread pool!
                    let proof = rpm.detectMimeFromBytes(for: fileURL)
                    let resolvedMime = rpm.resolveMime(claim: nil, proof: proof)
                    let mimeType = resolvedMime == "application/octet-stream" ? nil : resolvedMime

                    let mediaType: MediaItem.MediaType
                    if let mime = mimeType {
                        if mime.hasPrefix("video/") { mediaType = .video }
                        else if mime.hasPrefix("audio/") { mediaType = .audio }
                        else if mime.hasPrefix("image/") { mediaType = .image }
                        else { mediaType = .unknown }
                    } else {
                        mediaType = .unknown
                    }

                    return MediaItem(id: UUID(), url: serveURL, type: mediaType, dateAdded: date, pubkey: ownerHex, tags: nil, mimeType: mimeType)
                }
            }.value

            await MainActor.run {
                if cache.items.count != result.count {
                    #if DEBUG
                    print("ViewerView: Loaded \(result.count) Blossom media items")
                    #endif
                }
                cache.items = result
                cache.lastScanDate = Date()
                cache.isScanning = false
            }
        }
    }

    private func handleUploadSelectedItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }

        let blossom = blossomService

        for item in items {
            // Check ALL supported content types — .first can be a non-video type
            // even for videos (e.g. combined picker, HEVC, iCloud items).
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
            let contentType = item.supportedContentTypes.first ?? .image

            let filename = "media-\(UUID().uuidString.prefix(8))"

            // Create a structured task and store it to keep it alive
            let uploadTask = Task {
                let notificationId = await MainActor.run {
                    MediaUploadNotificationManager.shared.add(filename: filename)
                }

                if isVideo {
                    // Handle video upload — try file-based ImportedVideoFile first,
                    // fall back to Data if the system can't provide a .movie file
                    // representation (HEVC transcoding failure, iCloud-only items, etc.).
                    do {
                        var fileURL: URL?
                        var mimeType = "video/mp4"

                        if let video = try? await item.loadTransferable(type: ImportedVideoFile.self) {
                            let derivedType = UTType(filenameExtension: video.url.pathExtension) ?? contentType
                            mimeType = derivedType.preferredMIMEType ?? "video/mp4"
                            fileURL = video.url
                        } else if let data = try await item.loadTransferable(type: Data.self) {
                            // Fallback: write raw bytes to a temp file so we can stream the upload.
                            // Determine MIME from the first video-conformant supported type.
                            let videoType = item.supportedContentTypes.first { $0.conforms(to: .movie) || $0.conforms(to: .video) }
                            let ext = videoType?.preferredFilenameExtension ?? "mp4"
                            mimeType = videoType?.preferredMIMEType ?? "video/mp4"
                            let dest = FileManager.default.temporaryDirectory
                                .appendingPathComponent("haven-upload-\(UUID().uuidString)")
                                .appendingPathExtension(ext)
                            try data.write(to: dest)
                            fileURL = dest
                        }

                        guard let fileURL else {
                            await MainActor.run {
                                MediaUploadNotificationManager.shared.markFailed(id: notificationId, message: "Failed to read video file.")
                            }
                            return
                        }

                        guard let sha256 = ComposeView.streamingSHA256(of: fileURL) else {
                            await MainActor.run {
                                MediaUploadNotificationManager.shared.markFailed(id: notificationId, message: "Failed to compute SHA256.")
                            }
                            try? FileManager.default.removeItem(at: fileURL)
                            return
                        }

                        let localSuccess = await blossom.saveToLocalRelay(
                            fileURL: fileURL,
                            sha256: sha256,
                            contentType: mimeType
                        ) { progress in
                            Task { @MainActor in
                                MediaUploadNotificationManager.shared.updateProgress(id: notificationId, progress: progress)
                            }
                        }

                        try? FileManager.default.removeItem(at: fileURL)

                        await MainActor.run {
                            if localSuccess {
                                MediaUploadNotificationManager.shared.markSuccess(id: notificationId)
                                self.loadLocalMedia(force: true)
                            } else {
                                MediaUploadNotificationManager.shared.markFailed(id: notificationId, message: "Failed to upload video to local relay.")
                            }
                        }
                    } catch {
                        await MainActor.run {
                            MediaUploadNotificationManager.shared.markFailed(id: notificationId, message: error.localizedDescription)
                        }
                    }
                } else {
                    // Handle image upload - use async loadTransferable
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            await MainActor.run {
                                MediaUploadNotificationManager.shared.markFailed(id: notificationId, message: "Failed to read image data.")
                            }
                            return
                        }

                        var finalData = data
                        var finalType = contentType

                        // Convert HEIC/HEIF to JPEG
                        if contentType.conforms(to: .heic) || contentType.conforms(to: .heif) {
                            #if os(iOS)
                            if let image = UIImage(data: data),
                               let jpegData = image.jpegData(compressionQuality: 0.8) {
                                finalData = jpegData
                                finalType = .jpeg
                            }
                            #elseif os(macOS)
                            if let image = NSImage(data: data),
                               let tiffData = image.tiffRepresentation,
                               let bitmapRep = NSBitmapImageRep(data: tiffData),
                               let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                                finalData = jpegData
                                finalType = .jpeg
                            }
                            #endif
                        }

                        let mimeType = finalType.preferredMIMEType ?? "image/jpeg"
                        let sha256 = SHA256.hash(data: finalData).map { String(format: "%02x", $0) }.joined()

                        let localSuccess = await blossom.saveToLocalRelay(
                            data: finalData,
                            sha256: sha256,
                            contentType: mimeType
                        )

                        await MainActor.run {
                            if localSuccess {
                                MediaUploadNotificationManager.shared.markSuccess(id: notificationId)
                                self.loadLocalMedia(force: true)
                            } else {
                                MediaUploadNotificationManager.shared.markFailed(id: notificationId, message: "Failed to upload image to local relay.")
                            }
                        }
                    } catch {
                        await MainActor.run {
                            MediaUploadNotificationManager.shared.markFailed(id: notificationId, message: error.localizedDescription)
                        }
                    }
                }
            }

            // Store task to keep it alive
            activeUploadTasks.append(uploadTask)
        }

        // Clear selected items only AFTER creating all tasks
        self.selectedUploadItems = []

        // Clean up completed tasks periodically
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            activeUploadTasks.removeAll { $0.isCancelled || Task.isCancelled }
        }
    }

    private func handleUploadFileURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        
        let blossom = blossomService
        
        for url in urls {
            // Start accessing security scoped resource if required
            guard url.startAccessingSecurityScopedResource() else {
                continue
            }
            
            let filename = url.lastPathComponent
            
            Task { @MainActor in
                let notificationId = MediaUploadNotificationManager.shared.add(filename: filename)
                
                let derivedType = UTType(filenameExtension: url.pathExtension) ?? .item
                let mimeType = derivedType.preferredMIMEType ?? "application/octet-stream"
                
                Task {
                    defer {
                        url.stopAccessingSecurityScopedResource()
                    }
                    
                    // Copy the file to a temp location so we can read it safely without sandbox errors during async operation
                    let tempDest = FileManager.default.temporaryDirectory
                        .appendingPathComponent("haven-upload-\(UUID().uuidString)")
                        .appendingPathExtension(url.pathExtension)
                    
                    do {
                        try? FileManager.default.removeItem(at: tempDest)
                        try FileManager.default.copyItem(at: url, to: tempDest)
                    } catch {
                        await MainActor.run {
                            MediaUploadNotificationManager.shared.markFailed(id: notificationId, message: "Failed to read file.")
                        }
                        return
                    }
                    
                    guard let sha256 = ComposeView.streamingSHA256(of: tempDest) else {
                        try? FileManager.default.removeItem(at: tempDest)
                        await MainActor.run {
                            MediaUploadNotificationManager.shared.markFailed(id: notificationId, message: "Failed to compute SHA256.")
                        }
                        return
                    }
                    
                    let localSuccess = await blossom.saveToLocalRelay(
                        fileURL: tempDest,
                        sha256: sha256,
                        contentType: mimeType
                    ) { progress in
                        Task { @MainActor in
                            MediaUploadNotificationManager.shared.updateProgress(id: notificationId, progress: progress)
                        }
                    }

                    try? FileManager.default.removeItem(at: tempDest)

                    await MainActor.run {
                        if localSuccess {
                            MediaUploadNotificationManager.shared.markSuccess(id: notificationId)
                            loadLocalMedia(force: true)
                        } else {
                            MediaUploadNotificationManager.shared.markFailed(id: notificationId, message: "Failed to upload to local relay.")
                        }
                    }
                }
            }
        }
    }

    private func handlePasteFromClipboard() {
        // Set loading state immediately
        isPastingContent = true
        pasteError = nil

        Task {
            let blossom = blossomService
            var success = false
            var notificationId: UUID? = nil

            // SCENARIO 1: Check for image data first (higher priority)
            if PlatformClipboard.hasImage(), let imageData = PlatformClipboard.getImageData() {
                // Detect actual image format from magic bytes
                let detectedContentType: String
                if imageData.count >= 6 {
                    let prefix = imageData.prefix(6)
                    if prefix == Data("GIF87a".utf8) || prefix == Data("GIF89a".utf8) {
                        detectedContentType = "image/gif"
                    } else if imageData.prefix(4) == Data([137, 80, 78, 71]) {
                        detectedContentType = "image/png"
                    } else if imageData.prefix(4) == Data([82, 73, 70, 70]) && imageData.count >= 12 && imageData[8...11] == Data([87, 69, 66, 80]) {
                        detectedContentType = "image/webp"
                    } else {
                        detectedContentType = "image/jpeg"
                    }
                } else {
                    detectedContentType = "image/jpeg"
                }

                notificationId = await MainActor.run {
                    MediaUploadNotificationManager.shared.add(filename: "pasted-image")
                }

                let sha256 = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()

                success = await blossom.saveToLocalRelay(
                    data: imageData,
                    sha256: sha256,
                    contentType: detectedContentType
                )
            }
            // SCENARIO 2: Check for URL string
            else if let clipboardString = PlatformClipboard.getString() {
                let trimmed = clipboardString.trimmingCharacters(in: .whitespacesAndNewlines)

                guard let url = URL(string: trimmed),
                      url.scheme == "http" || url.scheme == "https" else {
                    await MainActor.run {
                        isPastingContent = false
                        pasteError = "Clipboard does not contain a valid URL or image"
                    }
                    return
                }

                let filename = url.lastPathComponent.isEmpty
                    ? "media-\(UUID().uuidString.prefix(8))"
                    : url.lastPathComponent

                notificationId = await MainActor.run {
                    MediaUploadNotificationManager.shared.add(filename: filename)
                }

                // Use existing BlossomService.downloadFromURL
                success = await blossom.downloadFromURL(url: url)
            }
            else {
                // Clipboard is empty or unsupported content
                await MainActor.run {
                    isPastingContent = false
                    pasteError = "Clipboard is empty or contains unsupported content"
                }
                return
            }

            // Update UI on main thread
            await MainActor.run {
                isPastingContent = false

                if success, let id = notificationId {
                    MediaUploadNotificationManager.shared.markSuccess(id: id)
                    loadLocalMedia(force: true)
                } else if let id = notificationId {
                    MediaUploadNotificationManager.shared.markFailed(
                        id: id,
                        message: "Failed to paste media"
                    )
                }
            }
        }
    }

    private func deleteMediaFromMirrors(item: MediaItem) {
        let sha256 = extractViewerSHA256(from: item.url)
        guard !sha256.isEmpty else { return }
        Task {
            let service = BlossomService(configService: configService, nostrService: nostrService)
            let success = await service.deleteFromMirrors(sha256: sha256)
            await MainActor.run {
                if success {
                    ActionToastManager.shared.show(icon: "trash", message: "Deleted from mirrors", color: Color(red: 0.2, green: 0.8, blue: 0.6))
                } else {
                    ActionToastManager.shared.show(icon: "exclamationmark.triangle.fill", message: "Failed to delete from mirrors", color: .red.opacity(0.85))
                }
            }
        }
    }

    private func deleteMediaEverywhere(item: MediaItem) {
        let sha256 = extractViewerSHA256(from: item.url)
        guard !sha256.isEmpty else { return }
        Task {
            let service = BlossomService(configService: configService, nostrService: nostrService)
            async let local = service.deleteFromLocal(sha256: sha256)
            async let mirrors = service.deleteFromMirrors(sha256: sha256)
            let (localOk, mirrorsOk) = await (local, mirrors)
            await MainActor.run {
                let succeeded = localOk || mirrorsOk
                if succeeded {
                    // Instantly clean up local state
                    self.blossomCache.items.removeAll(where: { normalizedKeyStatic(for: $0.url) == sha256 })
                    self.displayMedia.removeAll(where: { normalizedKeyStatic(for: $0.url) == sha256 })
                    
                    if selectedMedia?.url == item.url {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedMedia = nil
                            dragOffset = .zero
                        }
                    }
                    
                    scheduleUpdateDisplayData()
                }
                
                if localOk && mirrorsOk {
                    ActionToastManager.shared.show(icon: "trash", message: "Deleted", color: Color(red: 0.2, green: 0.8, blue: 0.6))
                } else if localOk {
                    ActionToastManager.shared.show(icon: "exclamationmark.triangle.fill", message: "Deleted locally (Mirrors failed)", color: .orange.opacity(0.85))
                } else if mirrorsOk {
                    ActionToastManager.shared.show(icon: "exclamationmark.triangle.fill", message: "Deleted from mirrors, local failed", color: .orange.opacity(0.85))
                } else {
                    ActionToastManager.shared.show(icon: "exclamationmark.triangle.fill", message: "Failed to delete", color: .red.opacity(0.85))
                }
            }
        }
    }

    private func extractViewerSHA256(from url: URL) -> String {
        return normalizedKeyStatic(for: url)
    }

}

// MARK: - LikedByRow

struct LikedByRow: View {
    let reactors: [(pubkey: String, emoji: String)]
    var latestDate: Date? = nil
    @EnvironmentObject var nostrService: NostrService
    @State private var showingReactors = false

    private var uniqueReactors: [(pubkey: String, emoji: String)] {
        var seen = Set<String>()
        return reactors.filter { seen.insert($0.pubkey).inserted }
    }

    var body: some View {
        let unique = uniqueReactors
        HStack(spacing: 6) {
            Image(systemName: "heart.fill")
                .font(.appSystem(size: 12, weight: .bold))
                .foregroundColor(.pink)

            HStack(spacing: -6) {
                ForEach(Array(unique.prefix(5).enumerated()), id: \.offset) { _, reactor in
                    let profile = nostrService.profiles[reactor.pubkey]
                    AvatarView(url: profile?.pictureURL, pubkey: reactor.pubkey, size: 22)
                        .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 1.5))
                        .shadow(color: Color.black.opacity(0.1), radius: 2)
                }
            }

            let names = unique.prefix(3).map { r -> String in
                nostrService.profiles[r.pubkey]?.bestName ?? "npub…" + String(r.pubkey.suffix(4))
            }
            let remaining = unique.count - names.count

            Text(likedByText(names: names, remaining: remaining))
                .font(.appSystem(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)

            if let date = latestDate {
                Text(timeAgo(from: date))
                    .font(.appSystem(size: 12, weight: .regular))
                    .foregroundColor(.secondary.opacity(0.7))
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            showingReactors = true
        }
        .sheet(isPresented: $showingReactors) {
            ReactorsListView(reactors: unique, onDismiss: { showingReactors = false })
                .environmentObject(nostrService)
        }
        .onAppear {
            let missing = unique.map(\.pubkey).filter { nostrService.profiles[$0] == nil }
            if !missing.isEmpty {
                nostrService.fetchMissingProfiles(for: missing)
            }
        }
    }

    private func likedByText(names: [String], remaining: Int) -> String {
        if names.isEmpty { return "" }
        var text = names.joined(separator: ", ")
        if remaining > 0 {
            text += " +\(remaining) more"
        }
        text += " liked"
        return text
    }

    private func timeAgo(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct ReactorsListView: View {
    let reactors: [(pubkey: String, emoji: String)]
    var onDismiss: (() -> Void)? = nil
    @EnvironmentObject var nostrService: NostrService
    @Environment(\.presentationMode) var presentationMode
    @State private var selectedProfilePubkey: String?

    var body: some View {
        NavigationView {
            List(Array(reactors.enumerated()), id: \.offset) { _, reactor in
                let profile = nostrService.profiles[reactor.pubkey]
                Button {
                    selectedProfilePubkey = reactor.pubkey
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(url: profile?.pictureURL, pubkey: reactor.pubkey, size: 40)
                            .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 2))
                            .shadow(color: Color.black.opacity(0.1), radius: 3)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile?.bestName ?? "npub…" + String(reactor.pubkey.suffix(6)))
                                .font(.appSystem(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                            if let nip05 = profile?.nip05, !nip05.isEmpty {
                                Text(nip05)
                                    .font(.appSystem(size: 13))
                                    .foregroundColor(Color.havenPurple)
                            }
                        }

                        Spacer()

                        Text(reactor.emoji)
                            .font(.appSystem(size: 20))

                        Image(systemName: "chevron.right")
                            .font(.appSystem(size: 12, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
            .navigationTitle("Liked By")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if let onDismiss = onDismiss {
                            onDismiss()
                        } else {
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                }
            }
            .sheet(item: Binding<IdentifiableString?>(
                get: { selectedProfilePubkey.map { IdentifiableString(id: $0) } },
                set: { selectedProfilePubkey = $0?.id }
            )) { p in
                ProfileView(pubkey: p.id, onDismiss: { selectedProfilePubkey = nil })
            }
        }
        #if os(macOS)
        .frame(minWidth: 300, minHeight: 400)
        #endif
    }
}

struct RepostersListView: View {
    let pubkeys: [String]
    var onDismiss: (() -> Void)? = nil
    @EnvironmentObject var nostrService: NostrService
    @Environment(\.presentationMode) var presentationMode
    @State private var selectedProfilePubkey: String?

    var body: some View {
        NavigationView {
            List(pubkeys, id: \.self) { pubkey in
                let profile = nostrService.profiles[pubkey]
                Button {
                    selectedProfilePubkey = pubkey
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(url: profile?.pictureURL, pubkey: pubkey, size: 40)
                            .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 2))
                            .shadow(color: Color.black.opacity(0.1), radius: 3)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile?.bestName ?? "npub\u{2026}" + String(pubkey.suffix(6)))
                                .font(.appSystem(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                            if let nip05 = profile?.nip05, !nip05.isEmpty {
                                Text(nip05)
                                    .font(.appSystem(size: 13))
                                    .foregroundColor(Color.havenPurple)
                            }
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.appSystem(size: 12, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
            .navigationTitle("Reposted By")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if let onDismiss = onDismiss {
                            onDismiss()
                        } else {
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                }
            }
            .sheet(item: Binding<IdentifiableString?>(
                get: { selectedProfilePubkey.map { IdentifiableString(id: $0) } },
                set: { selectedProfilePubkey = $0?.id }
            )) { p in
                ProfileView(pubkey: p.id, onDismiss: { selectedProfilePubkey = nil })
            }
        }
        #if os(macOS)
        .frame(minWidth: 300, minHeight: 400)
        #endif
    }
}

struct QuotersListView: View {
    let pubkeys: [String]
    var onDismiss: (() -> Void)? = nil
    @EnvironmentObject var nostrService: NostrService
    @Environment(\.presentationMode) var presentationMode
    @State private var selectedProfilePubkey: String?

    var body: some View {
        NavigationView {
            List(pubkeys, id: \.self) { pubkey in
                let profile = nostrService.profiles[pubkey]
                Button {
                    selectedProfilePubkey = pubkey
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(url: profile?.pictureURL, pubkey: pubkey, size: 40)
                            .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 2))
                            .shadow(color: Color.black.opacity(0.1), radius: 3)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile?.bestName ?? "npub\u{2026}" + String(pubkey.suffix(6)))
                                .font(.appSystem(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                            if let nip05 = profile?.nip05, !nip05.isEmpty {
                                Text(nip05)
                                    .font(.appSystem(size: 13))
                                    .foregroundColor(Color.havenPurple)
                            }
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.appSystem(size: 12, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
            .navigationTitle("Quoted By")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if let onDismiss = onDismiss {
                            onDismiss()
                        } else {
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                }
            }
            .sheet(item: Binding<IdentifiableString?>(
                get: { selectedProfilePubkey.map { IdentifiableString(id: $0) } },
                set: { selectedProfilePubkey = $0?.id }
            )) { p in
                ProfileView(pubkey: p.id, onDismiss: { selectedProfilePubkey = nil })
            }
        }
        #if os(macOS)
        .frame(minWidth: 300, minHeight: 400)
        #endif
    }
}

// MARK: - ZappedByRow

struct ZappedByRow: View {
    let zappers: [(pubkey: String, amount: Int64)]
    @EnvironmentObject var nostrService: NostrService

    private var uniqueZappers: [String] {
        var seen = Set<String>()
        return zappers.compactMap { z in
            if seen.contains(z.pubkey) { return nil }
            seen.insert(z.pubkey)
            return z.pubkey
        }
    }

    private var totalSats: Int64 {
        zappers.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        let unique = uniqueZappers
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
                .font(.appSystem(size: 11, weight: .bold))
                .foregroundColor(.orange)

            HStack(spacing: -6) {
                ForEach(unique.prefix(5), id: \.self) { pubkey in
                    let profile = nostrService.profiles[pubkey]
                    AvatarView(url: profile?.pictureURL, pubkey: pubkey, size: 20)
                        .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 1.5))
                }
            }

            let names = unique.prefix(3).map { pk -> String in
                nostrService.profiles[pk]?.bestName ?? "npub…" + String(pk.suffix(4))
            }
            let remaining = unique.count - names.count

            Text(zappedByText(names: names, remaining: remaining))
                .font(.appSystem(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer()
        }
        .onAppear {
            let missing = unique.filter { nostrService.profiles[$0] == nil }
            if !missing.isEmpty {
                nostrService.fetchMissingProfiles(for: missing)
            }
        }
    }

    private func zappedByText(names: [String], remaining: Int) -> String {
        if names.isEmpty { return "" }
        var text = names.joined(separator: ", ")
        if remaining > 0 {
            text += " +\(remaining) more"
        }
        text += " zapped"
        if totalSats > 0 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            let formatted = formatter.string(from: NSNumber(value: totalSats)) ?? "\(totalSats)"
            text += " · \(formatted) sats"
        }
        return text
    }
}

struct FilterButton: View {
    let title: String
    var icon: String? = nil
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.appSystem(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.appSystem(size: 11, weight: isSelected ? .bold : .regular, design: .monospaced))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundColor(isSelected ? .white : .secondary)
            .background(isSelected ? color : Color.clear)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? color.opacity(0.5) : Color.clear, lineWidth: 0.8)
            )
            .animation(.easeInOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}

struct IconFilterButton: View {
    let icon: String
    let tooltip: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if icon == "GIF" {
                    Text("GIF")
                        .font(.appSystem(size: 9, weight: .black, design: .rounded))
                        .foregroundColor(isSelected ? color : .secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(isSelected ? color : Color.secondary, lineWidth: 1.5)
                        )
                } else {
                    Image(systemName: icon)
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(isSelected ? color : .secondary)
                }
            }
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tooltip)
    }
}

struct ModeButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    var hasNotification: Bool = false
    let action: () -> Void

    private var accentTint: Color {
        Color.havenPurple
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(isSelected ? .white : (hasNotification ? accentTint : .white))
                Text(title)
                    .font(.appSystem(size: 13, weight: .semibold, design: .default))
                    .lineLimit(1)
                    .foregroundColor(isSelected ? .white : (hasNotification ? accentTint : .white))
            }
            .fixedSize()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isSelected ? .havenPurple : (hasNotification ? accentTint.opacity(0.15) : Color.clear))
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isSelected ? .havenPurple.opacity(0.5) : (hasNotification ? accentTint.opacity(0.4) : Color.clear), lineWidth: 0.8)
            )
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.2), value: isSelected)
            .animation(.easeInOut(duration: 0.3), value: hasNotification)
        }
        .buttonStyle(.plain)
    }
}

struct ProfileResultRow: View {
    let profile: FeedProfile
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 14) {
            AvatarView(url: profile.pictureURL, pubkey: profile.pubkey, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.bestName)
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if let nip05 = profile.nip05, !nip05.isEmpty {
                    Text(nip05)
                        .font(.appSystem(size: 12, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if let about = profile.about, !about.isEmpty {
                    Text(about)
                        .font(.appSystem(size: 13, weight: .regular))
                        .foregroundColor(.secondary.opacity(0.8))
                        .lineLimit(2)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.appSystem(size: 12, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isHovered ? Color.white.opacity(0.04) : Color.clear)
        .onHover { isHovered = $0 }
        .contentShape(Rectangle())
    }
}

struct NoteRow: View {
    let event: NostrEvent
    /// When true, clamp the body to a few lines and append a "Show more"
    /// affordance. Used by compact contexts like the likes/zaps lists.
    var truncate: Bool = false
    /// Layout mode for the note display
    var layoutMode: ViewerView.NoteLayoutMode = .expanded
    /// Optional inline engagement data rendered inside the card.
    var reactors: [(pubkey: String, emoji: String)]? = nil
    var latestReactionDate: Date? = nil
    var zappers: [(pubkey: String, amount: Int64)]? = nil
    var reposterPubkeys: [String]? = nil
    var quoterPubkeys: [String]? = nil
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @State private var isHovered = false
    @State private var showingReportDialog = false
    @State private var showingReactors = false
    @State private var showingReposters = false
    @State private var showingQuoters = false
    @State private var isExpanded = false
    
    var cleanContent: String {
        return event.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// For kind 6 reposts, parse the embedded JSON to extract the original note
    var repostedEvent: NostrEvent? {
        guard event.kind == 6,
              let data = event.content.data(using: .utf8),
              let inner = try? JSONDecoder().decode(NostrEvent.self, from: data) else {
            return nil
        }
        return inner
    }
    
    var displayName: String {
        let profile = nostrService.profiles[event.pubkey]
        if let profile = profile {
            return profile.bestName
        }
        return event.pubkey.prefix(8) + "..." + event.pubkey.suffix(4)
    }
    
    enum NoteType {
        case mine
        case whitelisted
        case tagged
        
        var label: String {
            switch self {
            case .mine: return "My Note"
            case .whitelisted: return "Whitelisted"
            case .tagged: return "Tagged"
            }
        }
        
        var icon: String {
            switch self {
            case .mine: return "pencil.line"
            case .whitelisted: return "checkmark.seal.fill" 
            case .tagged: return "tag.fill"
            }
        }
        
        @MainActor var color: Color {
            switch self {
            case .mine: return .havenPurple
            case .whitelisted: return .green
            case .tagged: return .blue
            }
        }
    }
    
    var noteType: NoteType {
        if event.pubkey == nostrService.activeHexPubkey {
            return .mine
        }
        if configService.whitelistedHexPubkeys.contains(event.pubkey) {
            return .whitelisted
        }
        return .tagged
    }
    
    var body: some View {
        Group {
            if layoutMode == .compact {
                compactLayout
            } else {
                expandedLayout
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if noteType != .mine {
                Button(action: {
                    showingReportDialog = true
                }) {
                    Label("Report Post", systemImage: "flag.fill")
                }

                Divider()

                Button(action: {
                    blockUser(hexPubkey: event.pubkey)
                }) {
                    Label("Block User", systemImage: "hand.raised.fill")
                }
            }
        }
        .sheet(isPresented: $showingReportDialog) {
            UGCReportingDialog(eventId: event.id, pubkey: event.pubkey, onDismiss: { showingReportDialog = false }) {
                // Background refresh will handle hiding it, but we can proactively trigger update
                nostrService.objectWillChange.send()
            }
            .environmentObject(nostrService)
            .environmentObject(configService)
        }
        .onAppear {
            if nostrService.profiles[event.pubkey] == nil {
                nostrService.fetchMissingProfiles(for: [event.pubkey])
            }
        }
    }

    // MARK: - Compact Layout
    /// A condensed single-row layout mirroring the Feed's compact mode:
    /// 32pt avatar, name · time header, two lines of plain text, and a small
    /// media thumbnail. No engagement bar — tapping the row opens the detail view.
    private var compactLayout: some View {
        let urls = event.mediaURLs
        let innerUrls = repostedEvent?.mediaURLs ?? []
        let firstMedia = urls.first ?? innerUrls.first
        let totalMedia = urls.count + innerUrls.count
        let contentToShow: String = {
            if event.kind == 6, cleanContent.isEmpty, let inner = repostedEvent {
                return inner.content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return cleanContent
        }()

        return HStack(alignment: .top, spacing: 8) {
            AvatarView(
                url: nostrService.profiles[event.pubkey]?.pictureURL,
                pubkey: event.pubkey,
                size: 32
            )
            .overlay(Circle().stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(displayName)
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Image(systemName: noteType.icon)
                        .font(.appSystem(size: 9))
                        .foregroundColor(noteType.color)

                    Text("· \(timeAgo(from: event.createdAtDate))")
                        .font(.appSystem(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if event.kind == 6 {
                        Image(systemName: "arrow.2.squarepath")
                            .font(.appSystem(size: 10))
                            .foregroundColor(.green.opacity(0.7))
                    }
                    if event.isReply {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.appSystem(size: 10))
                            .foregroundColor(Color.havenPurple.opacity(0.7))
                    }
                }

                if !contentToShow.isEmpty {
                    Text(NostrContentFormatter.resolveMentionsPlainText(contentToShow))
                        .font(.appSystem(size: 14))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .lineSpacing(1)
                }
            }

            Spacer(minLength: 8)

            if let firstMedia = firstMedia {
                ZStack(alignment: .bottomTrailing) {
                    FeedMediaView(url: firstMedia, isThumbnail: true)
                        .frame(width: 60, height: 60)
                        .aspectRatio(1, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    if totalMedia > 1 {
                        Text("+\(totalMedia - 1)")
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.7))
                            .clipShape(Capsule())
                            .padding(4)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            ZStack {
                Color.platformSecondaryGroupedBackground
                Color.havenPurple.opacity(0.015)
            }
        )
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.havenPurple.opacity(0.15), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Expanded Layout

    private var expandedLayout: some View {
        let avatarSize: CGFloat = layoutMode == .compact ? 32 : 40
        let headerSpacing: CGFloat = layoutMode == .compact ? 8 : 12
        let contentFontSize: CGFloat = layoutMode == .compact ? 14 : 15
        let cardSpacing: CGFloat = layoutMode == .compact ? 8 : 10

        return VStack(alignment: .leading, spacing: cardSpacing) {
            // Header with profile and timestamp
            HStack(alignment: .center, spacing: headerSpacing) {
                AvatarView(
                    url: nostrService.profiles[event.pubkey]?.pictureURL,
                    pubkey: event.pubkey,
                    size: avatarSize
                )
                .overlay(Circle().stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.appSystem(size: 14, weight: .semibold, design: .default))
                            .lineLimit(1)

                        if event.kind == 6 {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.2.squarepath")
                                    .font(.appSystem(size: 10, weight: .semibold))
                                Text("Reposted")
                                    .font(.appSystem(size: 11, weight: .medium))
                            }
                            .foregroundColor(.green)
                        }

                        if event.isReply {
                            HStack(spacing: 3) {
                                Image(systemName: "arrowshape.turn.up.left.fill")
                                    .font(.appSystem(size: 10, weight: .semibold))
                                Text("Reply")
                                    .font(.appSystem(size: 11, weight: .medium))
                            }
                            .foregroundColor(Color.havenPurple.opacity(0.7))
                        }

                        Image(systemName: noteType.icon)
                            .font(.appCaption2)
                            .foregroundColor(noteType.color)

                        Spacer()

                        Text(timeAgo(from: event.createdAtDate))
                            .font(.appSystem(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.2)
                    }
                }
            }

            // Repost: show the inner note's content
            if let inner = repostedEvent {
                RepostedNoteView(inner: inner)
                    .environmentObject(nostrService)
            } else {
                // Regular note content
                let urls = event.mediaURLs
                let links = event.linkURLs

                if !cleanContent.isEmpty {
                    Text(NostrContentFormatter.format(cleanContent, mediaURLs: urls))
                        .font(.appSystem(size: contentFontSize, weight: .regular, design: .default))
                        .foregroundColor(Color(red: 1, green: 1, blue: 1))
                        .lineSpacing(2)
                        .lineLimit(truncate && !isExpanded ? 8 : nil)
                        .fixedSize(horizontal: false, vertical: true)

                    if truncate && !isExpanded && cleanContent.count > 240 {
                        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded = true } }) {
                            Text("Show more")
                                .font(.appSystem(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(.havenPurple)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Media previews (photos, GIFs, videos)
                if !urls.isEmpty {
                    if urls.count == 1 {
                        FeedMediaView(url: urls[0], maxHeight: 300, portraitMaxHeight: 400, isThumbnail: false)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        TabView {
                            ForEach(urls, id: \.absoluteString) { url in
                                FeedMediaView(url: url, maxHeight: 300, portraitMaxHeight: 400, isThumbnail: false)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .mediaTabViewStyleCompat()
                        .frame(height: 300)
                    }
                }

                // Link preview
                if !links.isEmpty {
                    LinkPreviewCard(url: links[0])
                }
            }

            // Compact inline engagement bar
            let rxList = reactors ?? []
            let zpList = zappers ?? []
            let rpList = reposterPubkeys ?? []
            let qtList = quoterPubkeys ?? []
            if !rxList.isEmpty || !zpList.isEmpty || !rpList.isEmpty || !qtList.isEmpty {
                engagementBar(reactors: rxList, zaps: zpList, reposters: rpList, quoters: qtList)
            }
        }
        .padding(14)
        .background(
            ZStack {
                Color.platformSecondaryGroupedBackground
                Color.havenPurple.opacity(0.015)
            }
        )
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.havenPurple.opacity(0.12), lineWidth: 0.8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        #if os(iOS)
        .hoverEffect(.lift)
        #endif
        .clipped()
    }

    private func avatarGradientForType(_ type: NoteType) -> LinearGradient {
        switch type {
        case .mine:
            return LinearGradient(
                gradient: Gradient(colors: [
                    .havenPurple,
                    .havenPurpleLight
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .whitelisted:
            return LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.2, green: 0.8, blue: 0.6),
                    Color(red: 0.1, green: 0.7, blue: 0.5)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .tagged:
            return LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.2, green: 0.5, blue: 0.8),
                    Color(red: 0.3, green: 0.6, blue: 1.0)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private func blockUser(hexPubkey: String) {
        guard let data = Bech32.hexToData(hexPubkey),
              let npub = Bech32.encode(hrp: "npub", data: data) else { return }
        configService.blockProfile(npub)
    }

    func timeAgo(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Inline Engagement Bar

    @ViewBuilder
    private func engagementBar(reactors: [(pubkey: String, emoji: String)], zaps: [(pubkey: String, amount: Int64)], reposters: [String], quoters: [String]) -> some View {
        let uniqueReactors: [(pubkey: String, emoji: String)] = {
            var seen = Set<String>()
            return reactors.filter { seen.insert($0.pubkey).inserted }
        }()
        let uniqueZapperPubkeys: [String] = {
            var seen = Set<String>()
            return zaps.compactMap { z in
                if seen.contains(z.pubkey) { return nil }
                seen.insert(z.pubkey)
                return z.pubkey
            }
        }()
        let uniqueReposters: [String] = {
            var seen = Set<String>()
            return reposters.filter { seen.insert($0).inserted }
        }()
        let uniqueQuoters: [String] = {
            var seen = Set<String>()
            return quoters.filter { seen.insert($0).inserted }
        }()
        let totalSats = zaps.reduce(Int64(0)) { $0 + $1.amount }

        Rectangle()
            .fill(Color.secondary.opacity(0.12))
            .frame(height: 0.5)
            .padding(.top, 6)

        HStack(spacing: 14) {
            // Reactions
            if !uniqueReactors.isEmpty {
                Button {
                    showingReactors = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(.pink)

                        HStack(spacing: -4) {
                            ForEach(Array(uniqueReactors.prefix(3).enumerated()), id: \.offset) { _, reactor in
                                AvatarView(url: nostrService.profiles[reactor.pubkey]?.pictureURL, pubkey: reactor.pubkey, size: 16)
                                    .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 1))
                            }
                        }

                        Text("\(uniqueReactors.count)")
                            .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.pink.opacity(0.8))

                        if let date = latestReactionDate {
                            Text(timeAgo(from: date))
                                .font(.appSystem(size: 10, weight: .regular, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            // Reposts
            if !uniqueReposters.isEmpty {
                Button {
                    showingReposters = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.2.squarepath")
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(.green)

                        HStack(spacing: -4) {
                            ForEach(Array(uniqueReposters.prefix(3).enumerated()), id: \.element) { _, pubkey in
                                AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 16)
                                    .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 1))
                            }
                        }

                        Text("\(uniqueReposters.count)")
                            .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.green.opacity(0.8))
                    }
                }
                .buttonStyle(.plain)
            }

            // Quotes
            if !uniqueQuoters.isEmpty {
                Button {
                    showingQuoters = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "quote.bubble.fill")
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(.blue)

                        HStack(spacing: -4) {
                            ForEach(Array(uniqueQuoters.prefix(3).enumerated()), id: \.element) { _, pubkey in
                                AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 16)
                                    .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 1))
                            }
                        }

                        Text("\(uniqueQuoters.count)")
                            .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.blue.opacity(0.8))
                    }
                }
                .buttonStyle(.plain)
            }

            // Zaps
            if !uniqueZapperPubkeys.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.appSystem(size: 10, weight: .bold))
                        .foregroundColor(.orange)

                    HStack(spacing: -4) {
                        ForEach(Array(uniqueZapperPubkeys.prefix(3).enumerated()), id: \.element) { _, pubkey in
                            AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 16)
                                .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 1))
                        }
                    }

                    Text(Self.formatSats(totalSats))
                        .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange.opacity(0.8))
                }
            }

            Spacer()
        }
        .padding(.top, 6)
        .sheet(isPresented: $showingReactors) {
            ReactorsListView(reactors: uniqueReactors, onDismiss: { showingReactors = false })
                .environmentObject(nostrService)
        }
        .sheet(isPresented: $showingReposters) {
            RepostersListView(pubkeys: uniqueReposters, onDismiss: { showingReposters = false })
                .environmentObject(nostrService)
        }
        .sheet(isPresented: $showingQuoters) {
            QuotersListView(pubkeys: uniqueQuoters, onDismiss: { showingQuoters = false })
                .environmentObject(nostrService)
        }
        .onAppear {
            let allPubkeys = uniqueReactors.map(\.pubkey) + uniqueZapperPubkeys + uniqueReposters + uniqueQuoters
            let missing = allPubkeys.filter { nostrService.profiles[$0] == nil }
            if !missing.isEmpty {
                nostrService.fetchMissingProfiles(for: Array(Set(missing)))
            }
        }
    }

    private static func formatSats(_ sats: Int64) -> String {
        if sats >= 1_000_000 {
            let m = Double(sats) / 1_000_000.0
            return String(format: "%.1fM sats", m)
        } else if sats >= 10_000 {
            let k = Double(sats) / 1_000.0
            return String(format: "%.1fK sats", k)
        } else {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            return (formatter.string(from: NSNumber(value: sats)) ?? "\(sats)") + " sats"
        }
    }
}

struct RepostedNoteView: View {
    let inner: NostrEvent
    @EnvironmentObject var nostrService: NostrService

    private var innerDisplayName: String {
        if let profile = nostrService.profiles[inner.pubkey] {
            return profile.bestName
        }
        return inner.pubkey.prefix(8) + "..." + inner.pubkey.suffix(4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Inner note author header
            HStack(spacing: 8) {
                AvatarView(
                    url: nostrService.profiles[inner.pubkey]?.pictureURL,
                    pubkey: inner.pubkey,
                    size: 28
                )
                .overlay(Circle().stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.5))

                Text(innerDisplayName)
                    .font(.appSystem(size: 13, weight: .semibold))
                    .lineLimit(1)

                Spacer()

                Text(timeAgo(from: inner.createdAtDate))
                    .font(.appSystem(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Inner note content
            let urls = inner.mediaURLs
            let links = inner.linkURLs
            let content = inner.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                Text(NostrContentFormatter.format(content, mediaURLs: urls))
                    .font(.appSystem(size: 14, weight: .regular, design: .default))
                    .foregroundColor(Color(red: 0.9, green: 0.9, blue: 0.9))
                    .lineSpacing(2)
                    .lineLimit(nil)
            }

            // Media previews
            if !urls.isEmpty {
                if urls.count == 1 {
                    FeedMediaView(url: urls[0], maxHeight: 250, portraitMaxHeight: 350, isThumbnail: false)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    TabView {
                        ForEach(urls.prefix(4), id: \.absoluteString) { url in
                            FeedMediaView(url: url, maxHeight: 250, portraitMaxHeight: 350, isThumbnail: false)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .mediaTabViewStyleCompat()
                    .frame(height: 250)
                }
            }

            // Link preview
            if !links.isEmpty {
                LinkPreviewCard(url: links[0])
            }
        }
        .padding(10)
        .background(Color(red: 0.1, green: 0.1, blue: 0.14))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.5)
        )
        .onAppear {
            if nostrService.profiles[inner.pubkey] == nil {
                nostrService.fetchMissingProfiles(for: [inner.pubkey])
            }
        }
    }

    func timeAgo(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct MediaGridItem: View {
    let item: MediaItem
    var onDeleteFromMirrors: ((MediaItem) -> Void)? = nil
    var onDeleteEverywhere: ((MediaItem) -> Void)? = nil
    var onMirrorComplete: (() -> Void)? = nil
    let onSelect: () -> Void
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @State private var isHovered = false
    @State private var showingReportDialog = false
    @State private var isMirroringToLocal = false
    @State private var isPushingToMirrors = false
    @State private var mirrorStatusMessage: String?

    var body: some View {
        Color.clear
            .aspectRatio(1.0, contentMode: .fit)
            .overlay(
                Group {
                    // Use item.type instead of url extension checks for Blossom compatibility
                    if item.type == .video {
                        VideoThumbnailView(url: item.url, mimeType: item.mimeType)
                    } else if item.type == .audio {
                        ZStack {
                            Color(red: 0.1, green: 0.1, blue: 0.14)
                            Image(systemName: "waveform")
                                .font(.appSystem(size: 36))
                                .foregroundColor(.havenPurple)
                        }
                    } else if item.type == .unknown {
                        ZStack {
                            Color(red: 0.1, green: 0.1, blue: 0.14)
                            VStack(spacing: 4) {
                                Image(systemName: "doc.fill")
                                    .font(.appSystem(size: 28))
                                    .foregroundColor(.havenPurple.opacity(0.6))
                                if let mime = item.mimeType {
                                    Text(mime)
                                        .font(.appSystem(size: 9, weight: .medium, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(4)
                        }
                    } else if item.isAnimatedGIF {
                        AnimatedImage(url: item.url, contentMode: .fill, shouldAnimate: false, targetSize: CGSize(width: 250, height: 250))
                    } else {
                        // Default to image for non-video/audio items
                        RetryableAsyncImage(url: item.url, contentMode: .fill, targetSize: CGSize(width: 250, height: 250))
                    }
                }
            )
            .background(Color.black.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .scaleEffect(isHovered ? 1.04 : 1.0)
            .zIndex(isHovered ? 1.0 : 0.0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .onHover { hovering in isHovered = hovering }
            .onTapGesture { onSelect() }
        .contextMenu {
            Button(action: {
                PlatformClipboard.copy(item.shareURL(with: configService).absoluteString)
            }) {
                Label("Copy Link", systemImage: "doc.on.doc")
            }
            #if os(iOS)
            if item.type == .image || item.type == .video {
                Button(action: {
                    saveMediaToPhotos()
                }) {
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                }
            }
            #endif

            if !isOnMirror && configService.hasExternalShareURL(for: URL(string: "https://localhost")!) {
                Button(action: {
                    mirrorToLocalRelay()
                }) {
                    Label(isMirroringToLocal ? "Mirroring..." : "Mirror to Blossom", systemImage: "arrow.down.circle")
                }
                .disabled(isMirroringToLocal)
            }

            // Push local-only items to external mirrors
            if !isRemoteMedia && !configService.config.activeBlossomMirrors.isEmpty {
                Button(action: {
                    pushToMirrors()
                }) {
                    Label(isPushingToMirrors ? "Pushing..." : "Push to Mirrors", systemImage: "arrow.up.circle")
                }
                .disabled(isPushingToMirrors)
            }

            if onDeleteFromMirrors != nil || onDeleteEverywhere != nil {
                Menu {
                    if let onDeleteFromMirrors = onDeleteFromMirrors {
                        Button(role: .destructive, action: {
                            onDeleteFromMirrors(item)
                        }) {
                            Label("Delete from mirrors", systemImage: "trash")
                        }
                    }
                    if let onDeleteEverywhere = onDeleteEverywhere {
                        Button(role: .destructive, action: {
                            onDeleteEverywhere(item)
                        }) {
                            Label("Delete everywhere", systemImage: "trash.fill")
                        }
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }

            Divider()

            if MediaCacheService.shared.isKnown404(url: item.url) {
                Button(action: {
                    MediaCacheService.shared.unmarkNotFound(url: item.url)
                }) {
                    Label("Remove from 404", systemImage: "arrow.uturn.backward.circle")
                }
            } else {
                Button(action: {
                    MediaCacheService.shared.markNotFound(url: item.url)
                }) {
                    Label("Mark as 404", systemImage: "xmark.octagon")
                }
            }
            if let pubkey = item.pubkey, pubkey != nostrService.activeHexPubkey {
                Button(action: {
                    showingReportDialog = true
                }) {
                    Label("Report Media", systemImage: "flag.fill")
                }

                Divider()

                Button(action: {
                    guard let data = Bech32.hexToData(pubkey),
                          let npub = Bech32.encode(hrp: "npub", data: data) else { return }
                    configService.blockProfile(npub)
                }) {
                    Label("Block User", systemImage: "hand.raised.fill")
                }
            }
        }
        .sheet(isPresented: $showingReportDialog) {
            UGCReportingDialog(eventId: nil, pubkey: item.pubkey ?? "", onDismiss: { showingReportDialog = false }) {
                nostrService.objectWillChange.send()
            }
            .environmentObject(nostrService)
            .environmentObject(configService)
        }
    }

    private var isRemoteMedia: Bool {
        let host = item.url.host?.lowercased() ?? ""
        return host != "localhost" && host != "127.0.0.1" && host != "0.0.0.0"
    }

    private var isOnMirror: Bool {
        let currentMirrorHosts: Set<String> = Set(
            configService.config.activeBlossomMirrors.compactMap {
                URL(string: $0)?.host?.lowercased()
            }
        )
        guard let host = item.url.host?.lowercased() else { return false }
        return currentMirrorHosts.contains(host) || host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0"
    }

    private func mirrorToLocalRelay() {
        isMirroringToLocal = true
        Task {
            let service = BlossomService(configService: configService, nostrService: nostrService)
            let success = await service.downloadFromURL(url: item.url)
            await MainActor.run {
                isMirroringToLocal = false
                mirrorStatusMessage = success ? "Saved to local relay" : "Mirror failed"
                if success {
                    onMirrorComplete?()
                }
            }
        }
    }

    private func pushToMirrors() {
        isPushingToMirrors = true
        Task {
            let service = BlossomService(configService: configService, nostrService: nostrService)
            let sha256 = item.url.deletingPathExtension().lastPathComponent
            guard sha256.count == 64 && sha256.allSatisfy({ $0.isHexDigit }) else {
                await MainActor.run {
                    isPushingToMirrors = false
                    mirrorStatusMessage = "Could not extract hash"
                }
                return
            }
            let success = await service.pushLocalToMirrors(sha256: sha256)
            await MainActor.run {
                isPushingToMirrors = false
                mirrorStatusMessage = success ? "Pushed to mirrors" : "Push to mirrors failed"
            }
        }
    }

    #if os(iOS)
    private func saveMediaToPhotos(item: MediaItem) {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { return }

            let session = URLSession(configuration: .default, delegate: LocalhostTrustDelegate(), delegateQueue: nil)
            do {
                let (data, _) = try await session.data(from: item.url)

                if item.type == .video {
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
                    try data.write(to: tempURL)
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: tempURL, options: nil)
                    }
                    try? FileManager.default.removeItem(at: tempURL)
                } else {
                    try await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()
                        request.addResource(with: .photo, data: data, options: PHAssetResourceCreationOptions())
                    }
                }
            } catch {
                print("Save to Photos error: \(error.localizedDescription)")
            }
        }
    }

    private func saveMediaToPhotos() {
        saveMediaToPhotos(item: item)
    }
    #endif
}

struct MediaListItem: View {
    let item: MediaItem
    var onDeleteFromMirrors: ((MediaItem) -> Void)? = nil
    var onDeleteEverywhere: ((MediaItem) -> Void)? = nil
    var onMirrorComplete: (() -> Void)? = nil
    let onSelect: () -> Void
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @State private var showingReportDialog = false
    @State private var isMirroringToLocal = false
    @State private var isPushingToMirrors = false
    @State private var mirrorStatusMessage: String?
    @State private var mirroredCount: Int? = nil
    @State private var totalMirrors: Int = 0

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Thumbnail
                Color.clear
                    .aspectRatio(1.0, contentMode: .fit)
                    .frame(width: 60, height: 60)
                    .overlay(
                        Group {
                            if item.type == .video {
                                VideoThumbnailView(url: item.url, mimeType: item.mimeType)
                            } else if item.type == .audio {
                                ZStack {
                                    Color(red: 0.1, green: 0.1, blue: 0.14)
                                    Image(systemName: "waveform")
                                        .font(.appSystem(size: 20))
                                        .foregroundColor(.havenPurple)
                                }
                            } else if item.type == .unknown {
                                ZStack {
                                    Color(red: 0.1, green: 0.1, blue: 0.14)
                                    Image(systemName: "doc.fill")
                                        .font(.appSystem(size: 18))
                                        .foregroundColor(.havenPurple.opacity(0.6))
                                }
                            } else if item.isAnimatedGIF {
                                AnimatedImage(url: item.url, contentMode: .fill, shouldAnimate: false, targetSize: CGSize(width: 60, height: 60))
                            } else {
                                RetryableAsyncImage(url: item.url, contentMode: .fill, targetSize: CGSize(width: 60, height: 60))
                            }
                        }
                    )
                    .background(Color.black.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // Type Icon
                Image(systemName: item.type == .video ? "video.fill" : item.type == .audio ? "waveform" : item.type == .image ? "photo.fill" : "doc.fill")
                    .font(.appSystem(size: 20))
                    .foregroundColor(.havenPurple)
                    .frame(width: 32)

                // Location Status
                VStack(alignment: .leading, spacing: 4) {
                    if !isRemoteMedia {
                        HStack(spacing: 8) {
                            // Local storage — icon only
                            Image(systemName: "internaldrive.fill")
                                .font(.appSystem(size: 13))
                                .foregroundColor(.green)

                            // Blossom mirror count (x/x)
                            if totalMirrors > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "cloud.fill")
                                        .font(.appSystem(size: 11))
                                    Text(mirrorCountText)
                                        .font(.appSystem(size: 13, weight: .medium))
                                }
                                .foregroundColor(mirrorTint)
                            }
                        }
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "cloud.fill")
                                .font(.appSystem(size: 11))
                            Text(item.url.host ?? "Remote")
                                .font(.appSystem(size: 13, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundColor(.blue)
                    }
                }

                Spacer()

                // Action Buttons
                HStack(spacing: 8) {
                    // Upload to mirrors (only for local items with mirrors configured)
                    if !isRemoteMedia && !configService.config.activeBlossomMirrors.isEmpty {
                        Button(action: pushToMirrors) {
                            Image(systemName: isPushingToMirrors ? "arrow.up.circle.fill" : "arrow.up.circle")
                                .font(.appSystem(size: 22))
                                .foregroundColor(isPushingToMirrors ? .secondary : .havenPurple)
                        }
                        .buttonStyle(.plain)
                        .disabled(isPushingToMirrors)
                    }

                    // Download to local (only for remote items not on local)
                    if !isOnMirror && configService.hasExternalShareURL(for: URL(string: "https://localhost")!) {
                        Button(action: mirrorToLocalRelay) {
                            Image(systemName: isMirroringToLocal ? "arrow.down.circle.fill" : "arrow.down.circle")
                                .font(.appSystem(size: 22))
                                .foregroundColor(isMirroringToLocal ? .secondary : .havenPurple)
                        }
                        .buttonStyle(.plain)
                        .disabled(isMirroringToLocal)
                    }

                    // Copy link
                    Button(action: {
                        PlatformClipboard.copy(item.shareURL(with: configService).absoluteString)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.appSystem(size: 22))
                            .foregroundColor(.havenPurple)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 8)
            }
            .padding(12)
            .background(Color(red: 0.1, green: 0.1, blue: 0.14).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .task(id: item.id) {
            await loadMirrorCount()
        }
        .contextMenu {
            Button(action: {
                PlatformClipboard.copy(item.shareURL(with: configService).absoluteString)
            }) {
                Label("Copy Link", systemImage: "doc.on.doc")
            }
            #if os(iOS)
            if item.type == .image || item.type == .video {
                Button(action: {
                    saveMediaToPhotos()
                }) {
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                }
            }
            #endif

            if !isOnMirror && configService.hasExternalShareURL(for: URL(string: "https://localhost")!) {
                Button(action: {
                    mirrorToLocalRelay()
                }) {
                    Label(isMirroringToLocal ? "Mirroring..." : "Mirror to Blossom", systemImage: "arrow.down.circle")
                }
                .disabled(isMirroringToLocal)
            }

            if !isRemoteMedia && !configService.config.activeBlossomMirrors.isEmpty {
                Button(action: {
                    pushToMirrors()
                }) {
                    Label(isPushingToMirrors ? "Pushing..." : "Push to Mirrors", systemImage: "arrow.up.circle")
                }
                .disabled(isPushingToMirrors)
            }

            if onDeleteFromMirrors != nil || onDeleteEverywhere != nil {
                Menu {
                    if let onDeleteFromMirrors = onDeleteFromMirrors {
                        Button(role: .destructive, action: {
                            onDeleteFromMirrors(item)
                        }) {
                            Label("Delete from mirrors", systemImage: "trash")
                        }
                    }
                    if let onDeleteEverywhere = onDeleteEverywhere {
                        Button(role: .destructive, action: {
                            onDeleteEverywhere(item)
                        }) {
                            Label("Delete everywhere", systemImage: "trash.fill")
                        }
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }

            Divider()

            if MediaCacheService.shared.isKnown404(url: item.url) {
                Button(action: {
                    MediaCacheService.shared.unmarkNotFound(url: item.url)
                }) {
                    Label("Remove from 404", systemImage: "arrow.uturn.backward.circle")
                }
            } else {
                Button(action: {
                    MediaCacheService.shared.markNotFound(url: item.url)
                }) {
                    Label("Mark as 404", systemImage: "xmark.octagon")
                }
            }
            if let pubkey = item.pubkey, pubkey != nostrService.activeHexPubkey {
                Button(action: {
                    showingReportDialog = true
                }) {
                    Label("Report Media", systemImage: "flag.fill")
                }

                Divider()

                Button(action: {
                    guard let data = Bech32.hexToData(pubkey),
                          let npub = Bech32.encode(hrp: "npub", data: data) else { return }
                    configService.blockProfile(npub)
                }) {
                    Label("Block User", systemImage: "hand.raised.fill")
                }
            }
        }
        .sheet(isPresented: $showingReportDialog) {
            UGCReportingDialog(eventId: nil, pubkey: item.pubkey ?? "", onDismiss: { showingReportDialog = false }) {
                nostrService.objectWillChange.send()
            }
            .environmentObject(nostrService)
            .environmentObject(configService)
        }
    }

    private var isRemoteMedia: Bool {
        let host = item.url.host?.lowercased() ?? ""
        return host != "localhost" && host != "127.0.0.1" && host != "0.0.0.0"
    }

    private var isOnMirror: Bool {
        let currentMirrorHosts: Set<String> = Set(
            configService.config.activeBlossomMirrors.compactMap {
                URL(string: $0)?.host?.lowercased()
            }
        )
        guard let host = item.url.host?.lowercased() else { return false }
        return currentMirrorHosts.contains(host) || host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0"
    }

    private func mirrorToLocalRelay() {
        isMirroringToLocal = true
        Task {
            let service = BlossomService(configService: configService, nostrService: nostrService)
            let success = await service.downloadFromURL(url: item.url)
            await MainActor.run {
                isMirroringToLocal = false
                mirrorStatusMessage = success ? "Saved to local relay" : "Mirror failed"
                if success {
                    onMirrorComplete?()
                }
            }
        }
    }

    private func pushToMirrors() {
        isPushingToMirrors = true
        Task {
            let service = BlossomService(configService: configService, nostrService: nostrService)
            let sha256 = item.url.deletingPathExtension().lastPathComponent
            guard sha256.count == 64 && sha256.allSatisfy({ $0.isHexDigit }) else {
                await MainActor.run {
                    isPushingToMirrors = false
                    mirrorStatusMessage = "Could not extract hash"
                }
                return
            }
            let success = await service.pushLocalToMirrors(sha256: sha256)
            await MainActor.run {
                isPushingToMirrors = false
                mirrorStatusMessage = success ? "Pushed to mirrors" : "Push to mirrors failed"
            }
        }
    }

    #if os(iOS)
    private func saveMediaToPhotos(item: MediaItem) {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { return }

            let session = URLSession(configuration: .default, delegate: LocalhostTrustDelegate(), delegateQueue: nil)
            do {
                let (data, _) = try await session.data(from: item.url)

                if item.type == .video {
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
                    try data.write(to: tempURL)
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: tempURL, options: nil)
                    }
                    try? FileManager.default.removeItem(at: tempURL)
                } else {
                    try await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()
                        request.addResource(with: .photo, data: data, options: PHAssetResourceCreationOptions())
                    }
                }
            } catch {
                print("Save to Photos error: \(error.localizedDescription)")
            }
        }
    }

    private func saveMediaToPhotos() {
        saveMediaToPhotos(item: item)
    }
    #endif

    /// Cloud label text, e.g. "2/3". Shows the total while the count is loading.
    private var mirrorCountText: String {
        if let count = mirroredCount {
            return "\(count)/\(totalMirrors)"
        }
        return "–/\(totalMirrors)"
    }

    /// Tint for the cloud badge: gray while loading / not mirrored, orange when
    /// partially mirrored, green when present on every configured mirror.
    private var mirrorTint: Color {
        guard let count = mirroredCount, count > 0 else { return .secondary }
        return count >= totalMirrors ? .green : .orange
    }

    /// Checks how many configured Blossom mirrors hold this blob.
    private func loadMirrorCount() async {
        guard !isRemoteMedia else { return }
        let mirrors = configService.config.activeBlossomMirrors
        await MainActor.run { totalMirrors = mirrors.count }
        guard !mirrors.isEmpty else { return }

        let sha256 = item.url.deletingPathExtension().lastPathComponent
        guard sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit }) else { return }

        let service = BlossomService(configService: configService, nostrService: nostrService)
        let status = await service.checkMirrorStatus(sha256: sha256)
        let count = status.values.filter { $0 }.count
        await MainActor.run { mirroredCount = count }
    }
}

struct RetryableAsyncImage: View {
    @EnvironmentObject var configService: ConfigService
    let url: URL
    let contentMode: ContentMode
    var targetSize: CGSize? = nil
    @State private var id = UUID()
    @State private var retryCount = 0
    @State private var cachedImage: PlatformImage? = nil
    @State private var isLoading = false
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image = cachedImage {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else if isLoading {
                    ZStack {
                        Rectangle().fill(Color.gray.opacity(0.1))
                        ProgressView().controlSize(.small)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    AsyncImage(url: url, transaction: Transaction(animation: .default)) { phase in
                        switch phase {
                        case .empty:
                            ZStack {
                                Rectangle().fill(Color.gray.opacity(0.1))
                                ProgressView().controlSize(.small)
                            }
                        case .success(let image):
                            image.resizable()
                                .aspectRatio(contentMode: contentMode)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .onAppear {
                                    // checkCache() will handle caching logic
                                }
                        case .failure:
                             ZStack {
                                Rectangle().fill(Color.havenPurplePale.opacity(0.3))
                                VStack(spacing: 6) {
                                    Image(systemName: "photo.fill.on.rectangle.fill")
                                        .font(.appSystem(size: 28))
                                        .foregroundColor(.havenPurple.opacity(0.8))
                                    
                                    VStack(spacing: 2) {
                                        Text("Media Missing")
                                            .font(.appSystem(size: 11, weight: .bold))
                                        Text("Error 404")
                                            .font(.appSystem(size: 9))
                                            .textCase(.uppercase)
                                    }
                                    .foregroundColor(.havenPurple)
                                    
                                    Button(action: {
                                        id = UUID()
                                        retryCount += 1
                                        checkCache()
                                    }) {
                                        Text("Try Again")
                                            .font(.appSystem(size: 10, weight: .bold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(Color.havenPurple)
                                            .foregroundColor(.white)
                                            .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.top, 4)
                                }
                                .padding(8)
                            }
                        @unknown default:
                            EmptyView()
                        }
                    }
                }
            }
        }
        .id(id)
        .onAppear {
            checkCache()
        }
    }
    
    private func checkCache() {
        // 1. Try to load it directly from disk cache (General cache or Blossom)
        if let data = MediaCacheService.shared.loadFromCache(url: url) {
            Task {
                if let image = await decode(data: data) {
                    await MainActor.run {
                        self.cachedImage = image
                    }
                } else {
                    await handleMissedCache()
                }
            }
            return
        }
        
        Task {
            await handleMissedCache()
        }
    }
    
    private func handleMissedCache() async {
        // 2. If it's a grid item (targetSize set) or not found, try fetching
        // Note: For local Blossom, fetchData just pulls from local server but does not re-cache
        if targetSize != nil || self.cachedImage == nil {
            autoCache()
        }
    }
    
    private func autoCache() {
        isLoading = true
        Task {
            if let data = await MediaCacheService.shared.fetchData(url: url),
               let image = await decode(data: data) {
                await MainActor.run {
                    self.cachedImage = image
                    self.isLoading = false
                }
            } else {
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
    }
    
    nonisolated private func decode(data: Data) async -> PlatformImage? {
        if let targetSize = targetSize,
           let downsampled = await ImageDownsampler.downsample(data: data, maxDimension: max(targetSize.width, targetSize.height)) {
            return downsampled
        }
        return await Task.detached(priority: .utility) {
            PlatformImage(data: data)
        }.value
    }
}

struct VideoThumbnailView: View {
    let url: URL
    let mimeType: String?
    @State private var thumbnail: PlatformImage?
    @State private var isLoading: Bool
    @State private var id = UUID()

    init(url: URL, mimeType: String? = nil) {
        self.url = url
        self.mimeType = mimeType
        // Seed from cache so we never show a loading flash on subsequent renders.
        let cached = MediaCacheService.shared.cachedThumbnail(for: url)
        _thumbnail = State(initialValue: cached)
        _isLoading = State(initialValue: cached == nil)
    }
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image = thumbnail {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    
                    Image(systemName: "play.circle.fill")
                        .font(.appSystem(size: 40))
                        .foregroundColor(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                } else if isLoading {
                    ZStack {
                        LinearGradient(
                            colors: [Color.platformSecondaryGroupedBackground, Color(red: 0.06, green: 0.06, blue: 0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white.opacity(0.6))
                        
                        Image(systemName: "play.circle.fill")
                            .font(.appSystem(size: 40))
                            .foregroundColor(.white.opacity(0.3))
                            .shadow(radius: 2)
                    }
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [Color(red: 0.16, green: 0.16, blue: 0.22), Color(red: 0.08, green: 0.08, blue: 0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        
                        VStack(spacing: 6) {
                            Image(systemName: "video.fill")
                                .font(.appSystem(size: 22))
                                .foregroundColor(.havenPurple.opacity(0.7))
                            
                            Text("Video")
                                .font(.appSystem(size: 10, weight: .bold, design: .default))
                                .foregroundColor(.secondary.opacity(0.8))
                                .tracking(0.5)
                        }
                        .padding(.bottom, 4)
                        
                        Image(systemName: "play.circle.fill")
                            .font(.appSystem(size: 40))
                            .foregroundColor(.white.opacity(0.75))
                            .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .id(id)
        .onAppear {
            loadThumbnail()
        }
    }
    
    private func loadThumbnail() {
        if thumbnail != nil { return }
        isLoading = true

        Task {
            let image = await MediaCacheService.shared.generateThumbnail(for: url, mimeType: mimeType)
            await MainActor.run {
                self.thumbnail = image
                self.isLoading = false
            }
        }
    }
}

struct SourceIndicatorView: View {
    let url: URL
    var onMirrorComplete: (() -> Void)? = nil
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @State private var source: MediaCacheService.MediaSource = .remote
    @State private var isCaching = false
    @State private var isMirroring = false
    @State private var showMirrorStatus = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: source.icon)
                Text(source.rawValue)
                    .font(.appSystem(size: 11, weight: .bold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(source.color.opacity(0.2))
            .foregroundColor(source.color)
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(source.color.opacity(0.3), lineWidth: 1)
            )
            .onTapGesture {
                if source == .blossom {
                    showMirrorStatus = true
                }
            }
            
            if source == .remote {
                Button(action: cacheMedia) {
                    if isCaching {
                        ProgressView().controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        Label("Cache Locally", systemImage: "square.and.arrow.down")
                            .font(.appSystem(size: 11, weight: .bold))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isCaching)
            }
            
            if source == .cached && configService.hasExternalShareURL(for: URL(string: "https://localhost")!) {
                Button(action: mirrorToBlossom) {
                    if isMirroring {
                        ProgressView().controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        Label("Mirror to Blossom", systemImage: "arrow.down.circle")
                            .font(.appSystem(size: 11, weight: .bold))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isMirroring)
            }
        }
        .onAppear {
            updateSource()
        }
        .sheet(isPresented: $showMirrorStatus) {
            MirrorStatusSheet(url: url)
                .environmentObject(configService)
                .environmentObject(nostrService)
        }
    }
    
    private func updateSource() {
        source = MediaCacheService.shared.getSource(for: url)
    }
    
    private func cacheMedia() {
        isCaching = true
        MediaSessionService.shared.session.dataTask(with: url) { data, response, _ in
            if let data = data, let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                MediaCacheService.shared.saveToCache(url: url, data: data)
                DispatchQueue.main.async {
                    source = .cached
                    isCaching = false
                }
            } else {
                DispatchQueue.main.async {
                    isCaching = false
                }
            }
        }.resume()
    }
    
    private func mirrorToBlossom() {
        isMirroring = true
        Task {
            let service = BlossomService(configService: configService, nostrService: nostrService)
            let success = await service.downloadFromURL(url: url, mirrorToExternal: true)
            await MainActor.run {
                isMirroring = false
                if success {
                    source = .blossom
                    onMirrorComplete?()
                }
            }
        }
    }
}

// MARK: - MirrorStatusSheet

struct MirrorStatusSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService

    @State private var mirrorStatus: [String: Bool] = [:]
    @State private var isLoading = true
    @State private var sha256Hash: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if isLoading {
                    ProgressView("Checking mirrors...")
                        .padding()
                } else if mirrorStatus.isEmpty {
                    ContentUnavailableView(
                        "No Mirrors Configured",
                        systemImage: "server.rack",
                        description: Text("Configure Blossom mirrors in Settings to enable external backup")
                    )
                } else {
                    List {
                        Section {
                            if let hash = sha256Hash {
                                HStack {
                                    Text("Hash")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(hash.prefix(16) + "...")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Section("Mirror Status") {
                            ForEach(Array(mirrorStatus.keys.sorted()), id: \.self) { mirror in
                                HStack {
                                    Image(systemName: mirrorStatus[mirror] == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundColor(mirrorStatus[mirror] == true ? .green : .red)

                                    VStack(alignment: .leading, spacing: 2) {
                                        if let host = URL(string: mirror)?.host {
                                            Text(host)
                                                .font(.appSystem(size: 14, weight: .semibold))
                                        }
                                        Text(mirror)
                                            .font(.appSystem(size: 11))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    if mirrorStatus[mirror] == true {
                                        Text("Available")
                                            .font(.appSystem(size: 11, weight: .medium))
                                            .foregroundColor(.green)
                                    } else {
                                        Text("Not Found")
                                            .font(.appSystem(size: 11, weight: .medium))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Blossom Mirrors")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await checkMirrors()
        }
    }

    private func checkMirrors() async {
        isLoading = true

        // Extract hash from URL
        let lastComponent = url.deletingPathExtension().lastPathComponent
        if lastComponent.count == 64, lastComponent.allSatisfy({ $0.isHexDigit }) {
            sha256Hash = lastComponent

            let service = BlossomService(configService: configService, nostrService: nostrService)
            let status = await service.checkMirrorStatus(sha256: lastComponent)

            await MainActor.run {
                mirrorStatus = status
                isLoading = false
            }
        } else {
            await MainActor.run {
                isLoading = false
            }
        }
    }
}

// MARK: - ViewerChangeHandlers

/// Extracted onChange modifiers to reduce type-checker complexity in ViewerView.
struct ViewerChangeHandlers: ViewModifier {
    let viewMode: ViewerView.ViewMode
    let likesFilter: ViewerView.LikesFilter
    let zapsFilter: ViewerView.ZapsFilter
    let committedSearch: String
    let searchScope: ViewerView.SearchScope
    let contentFilter: ViewerView.ContentFilter
    let mediaSourceFilter: ViewerView.MediaSourceFilter
    let mediaLocationFilter: ViewerView.MediaLocationFilter
    let mediaTypeFilter: Set<ViewerView.MediaTypeFilter>
    let eventsCount: Int
    let noteMediaCount: Int
    let blacklistedNpubs: [String]
    let activeAccountNpub: String
    let blossomCount: Int
    let onResetAndUpdate: () -> Void
    let onUpdate: () -> Void
    let onViewModeChange: (ViewerView.ViewMode) -> Void
    let onEventsChange: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: committedSearch) { _, _ in onResetAndUpdate() }
            .onChange(of: searchScope) { _, _ in onResetAndUpdate() }
            .onChange(of: contentFilter) { _, _ in onResetAndUpdate() }
            .onChange(of: mediaSourceFilter) { _, _ in onUpdate() }
            .onChange(of: mediaLocationFilter) { _, _ in onUpdate() }
            .onChange(of: mediaTypeFilter) { _, _ in onUpdate() }
            .onChange(of: likesFilter) { _, _ in onResetAndUpdate() }
            .onChange(of: zapsFilter) { _, _ in onResetAndUpdate() }
            .onChange(of: viewMode) { _, newMode in onViewModeChange(newMode) }
            .onChange(of: eventsCount) { _, _ in onEventsChange() }
            .onChange(of: noteMediaCount) { _, _ in onUpdate() }
            .onChange(of: blacklistedNpubs) { _, _ in onUpdate() }
            .onChange(of: activeAccountNpub) { _, _ in onResetAndUpdate() }
            .onChange(of: blossomCount) { _, _ in onUpdate() }
    }
}

struct ViewerViewMediaItem: View {
    let mediaItem: MediaItem
    @State private var resolvedType: MediaItem.MediaType
    @State private var isLoadingType = false
    
    init(mediaItem: MediaItem) {
        self.mediaItem = mediaItem
        self._resolvedType = State(initialValue: mediaItem.type)
    }
    
    private var isVideoByMime: Bool {
        mediaItem.mimeType?.lowercased().hasPrefix("video/") == true
    }

    var body: some View {
        Group {
            if isLoadingType {
                ProgressView()
                    .tint(.white)
            } else if resolvedType == .video || isVideoByMime {
                VideoPlayerView(url: mediaItem.url, mimeType: mediaItem.mimeType)
            } else if resolvedType == .audio {
                AudioPlayerView(url: mediaItem.url)
            } else if resolvedType == .unknown {
                VStack(spacing: 12) {
                    Image(systemName: "doc.fill")
                        .font(.appSystem(size: 64))
                        .foregroundColor(Color.havenPurple.opacity(0.6))
                    if let mime = mediaItem.mimeType {
                        Text(mime)
                            .font(.appSystem(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    } else {
                        Text("Unknown Format")
                            .font(.appHeadline)
                            .foregroundColor(.secondary)
                    }
                }
            } else if mediaItem.isAnimatedGIF {
                AnimatedImage(url: mediaItem.url, contentMode: .fit, shouldAnimate: true)
            } else {
                RetryableAsyncImage(url: mediaItem.url, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            detectType()
        }
    }
    
    private func detectType() {
        if resolvedType != .unknown {
            return
        }
        
        let ext = mediaItem.url.pathExtension.lowercased()
        if SupportedMediaFormats.videoExtensions.contains(ext) {
            resolvedType = .video
        } else if SupportedMediaFormats.imageOrGifExtensions.contains(ext) {
            resolvedType = .image
        } else if SupportedMediaFormats.audioExtensions.contains(ext) {
            resolvedType = .audio
        } else if let cached = MediaTypeDetector.shared.getCachedContentType(for: mediaItem.url) {
            if MediaTypeDetector.shared.isVideoContentType(cached) {
                resolvedType = .video
            } else if MediaTypeDetector.shared.isImageContentType(cached) {
                resolvedType = .image
            } else {
                resolvedType = .unknown
            }
        } else {
            isLoadingType = true
            MediaTypeDetector.shared.detectContentType(for: mediaItem.url) { detectedType in
                isLoadingType = false
                if let detectedType = detectedType {
                    if MediaTypeDetector.shared.isVideoContentType(detectedType) {
                        resolvedType = .video
                    } else if MediaTypeDetector.shared.isImageContentType(detectedType) {
                        resolvedType = .image
                    } else {
                        resolvedType = .unknown
                    }
                } else {
                    resolvedType = .unknown
                }
            }
        }
    }
}
