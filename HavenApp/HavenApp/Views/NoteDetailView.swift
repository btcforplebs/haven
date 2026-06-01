import SwiftUI
import Combine


struct NoteDetailView: View {
    let note: FeedNote
    @StateObject private var feedService = FeedService.shared
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @Environment(\.presentationMode) var presentationMode
    
    @State private var composeContext: ComposeContext?
    @State private var isLoadingReplies = false
    @State private var pendingReplies: [FeedNote] = []
    @State private var parentNotes: [FeedNote] = []
    @State private var isLoadingParents = false
    @State private var threadClient: WebSocketClient?
    @State private var cancellables = Set<AnyCancellable>()
    @State private var showingProfilePubkey: String?
    @State private var showingNoteId: String?
    @State private var showingMediaUrl: IdentifiableURL?
    @State private var showingReportDialog = false
    @State private var showingDeleteConfirm = false
    @State private var showingEmojiPicker = false
    @State private var showingBroadcastSheet = false
    @State private var noLightningAddressAlert = false

    @State private var detailedReactions: [NostrEvent] = []
    @State private var detailedReposts: [NostrEvent] = []
    @State private var detailedZaps: [NostrEvent] = []
    
    @State private var showingZappersSheet = false
    @State private var showingReactorsSheet = false
    @State private var showingRepostersSheet = false

    // Expanded engagement across all thread notes
    @State private var expandedEngagement = false
    @State private var perNoteReactions: [String: [NostrEvent]] = [:]
    @State private var perNoteReposts: [String: [NostrEvent]] = [:]
    @State private var perNoteZaps: [String: [NostrEvent]] = [:]
    @State private var isLoadingExpandedEngagement = false

    @State private var focusedNoteId: String = ""

    private var threadRootId: String {
        let eTags = note.tags.filter { $0.count >= 2 && $0[0] == "e" }
        if let explicitRoot = eTags.first(where: { $0.count >= 4 && $0[3] == "root" }) {
            return explicitRoot[1]
        }
        return eTags.first?[1] ?? note.id
    }

    private var focusedNote: FeedNote {
        if focusedNoteId.isEmpty {
            return note
        }
        return feedService.findNote(id: focusedNoteId) ?? note
    }

    private var dynamicParents: [FeedNote] {
        var ancestors: [FeedNote] = []
        var current = focusedNote
        while let parentId = current.parentEventId {
            if let parent = feedService.findNote(id: parentId) {
                ancestors.insert(parent, at: 0)
                current = parent
            } else if let parentFromList = parentNotes.first(where: { $0.id == parentId }) {
                ancestors.insert(parentFromList, at: 0)
                current = parentFromList
            } else {
                break
            }
        }
        return ancestors
    }

    private var dynamicReplies: [FeedNote] {
        let targetId = (focusedNote.kind == 6 && focusedNote.repostedEventId != nil) ? focusedNote.repostedEventId! : focusedNote.id
        return feedService.notes.filter { $0.parentEventId == targetId }
            .sorted(by: { $0.createdAt < $1.createdAt })
    }

    private func selectAndScrollToNote(_ targetId: String, proxy: ScrollViewProxy) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            focusedNoteId = targetId
            proxy.scrollTo(targetId, anchor: .center)
        }
    }

    private var noteDetailFeedActions: FeedActions {
        .make(feedService: feedService, nostrService: nostrService)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Thread History (Parents) — only revealed once all parents are loaded
                    if !dynamicParents.isEmpty && !isLoadingParents {
                        threadSection(proxy: proxy)
                            .transition(.opacity)
                    }

                    // Loading indicator while thread is being fetched
                    if isLoadingParents && note.parentEventId != nil {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Color.havenPurple)
                            Text("Loading thread\u{2026}")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .transition(.opacity)
                    }

                    // Main Note (focused hero note) + engagement merged into one card
                    mainNoteSection(proxy: proxy)

                    // Replies Section
                    repliesSection(proxy: proxy)


                }
                .padding(.top, 16)
                .padding(.bottom, 90)
            }
            .onChange(of: isLoadingParents) { _, loading in
                if !loading {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                            let target = focusedNoteId.isEmpty ? note.id : focusedNoteId
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
            }
            .onChange(of: focusedNoteId) { _, newId in
                if !newId.isEmpty {
                    fetchEngagement(for: newId)
                }
            }
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.1))
        .refreshable {
            #if os(iOS)
            MacRelaySyncService.shared.syncIfConfigured()
            #endif
            fetchParents()
            fetchReplies()
        }
        .navigationTitle("Note")
        .environment(\.feedActions, noteDetailFeedActions)

        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            expandedEngagement.toggle()
                        }
                        if expandedEngagement {
                            fetchAllThreadEngagement()
                        }
                    } label: {
                        Image(systemName: expandedEngagement ? "chart.bar.fill" : "chart.bar")
                            .foregroundColor(expandedEngagement ? Color.havenPurple : nil)
                    }

                    Button {
                        let replyTarget: FeedNote = {
                            if note.kind == 6, let refId = note.repostedEventId,
                               let original = feedService.findNote(id: refId) {
                                return original
                            }
                            return note
                        }()
                        composeContext = ComposeContext(replyTo: replyTarget, quoteTo: nil)
                    } label: {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                    }

                    Menu {
                        if note.pubkey == nostrService.activeHexPubkey {
                            Button(role: .destructive, action: {
                                showingDeleteConfirm = true
                            }) {
                                Label("Delete Post", systemImage: "trash")
                            }
                        }

                        Button(action: {
                            showingReportDialog = true
                        }) {
                            Label("Report Post", systemImage: "flag.fill")
                        }

                        Button(action: {
                            blockUser(hexPubkey: note.pubkey)
                        }) {
                            Label("Block User", systemImage: "hand.raised.fill")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(item: $composeContext) { ctx in
            ComposeView(onDismiss: { composeContext = nil }, replyTo: ctx.replyTo, quoteTo: ctx.quoteTo)
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(isPresented: $showingReportDialog) {
            UGCReportingDialog(eventId: note.id, pubkey: note.pubkey, onDismiss: { showingReportDialog = false }) {
                nostrService.objectWillChange.send()
                showingReportDialog = false
            }
            .environmentObject(nostrService)
            .environmentObject(configService)
        }
        .onAppear {
            detailedReactions.removeAll()
            detailedReposts.removeAll()
            detailedZaps.removeAll()
            if focusedNoteId.isEmpty {
                focusedNoteId = note.id
            }
            fetchParents()
            fetchReplies()
            feedService.fetchNoteStats(for: note.id)
            let profile = nostrService.profiles[note.pubkey]
            if profile == nil {
                nostrService.fetchMissingProfiles(for: [note.pubkey])
            }
        }
        .onDisappear {
            threadClient?.disconnect()
            cancellables.removeAll()
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
        .sheet(item: $showingMediaUrl) { media in
            FeedMediaViewer(url: media.url, onDismiss: { showingMediaUrl = nil })
        }
        .sheet(isPresented: $showingBroadcastSheet) {
            EventBroadcastSheet(note: note)
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(isPresented: $showingZappersSheet) {
            ZappersListView(zaps: parsedZaps, onDismiss: { showingZappersSheet = false })
                .environmentObject(nostrService)
        }
        .sheet(isPresented: $showingReactorsSheet) {
            ReactorsListView(reactors: reactorsMapped, onDismiss: { showingReactorsSheet = false })
                .environmentObject(nostrService)
        }
        .sheet(isPresented: $showingRepostersSheet) {
            RepostersListView(pubkeys: repostersMapped, onDismiss: { showingRepostersSheet = false })
                .environmentObject(nostrService)
        }
        .alert("No Lightning Address", isPresented: $noLightningAddressAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This user hasn't configured a lightning address, so they can't receive zaps.")
        }
        .alert("Delete Post", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) {
                nostrService.deleteNote(id: note.id)
                FeedService.shared.removeNote(id: note.id)
                presentationMode.wrappedValue.dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Request deletion of this post? Not all relays honor NIP-09 deletion requests.")
        }
    }
    
    private func mainNoteSection(proxy: ScrollViewProxy) -> some View {
        let profile = nostrService.profiles[focusedNote.pubkey]
        let rowData = FeedNoteRowData.resolve(
            for: focusedNote,
            feedService: feedService,
            nostrService: nostrService
        )
        let hasEngagement = !detailedReactions.isEmpty || !detailedZaps.isEmpty || !detailedReposts.isEmpty

        return VStack(alignment: .leading, spacing: 0) {
            FeedNoteRow(
                note: focusedNote,
                profile: profile,
                rowData: rowData,
                onReply: {
                    let replyTarget: FeedNote = {
                        if focusedNote.kind == 6, let refId = focusedNote.repostedEventId,
                           let original = feedService.findNote(id: refId) {
                            return original
                        }
                        return focusedNote
                    }()
                    composeContext = ComposeContext(replyTo: replyTarget, quoteTo: nil)
                },
                onQuote: {
                    composeContext = ComposeContext(replyTo: nil, quoteTo: focusedNote)
                },
                onProfile: { pubkey in
                    showingProfilePubkey = pubkey
                },
                onMedia: { url in
                    showingMediaUrl = IdentifiableURL(url: url)
                },
                showParent: false,
                layoutMode: .wide,
                isFocused: true,
                suppressCardStyling: true
            )

            if hasEngagement {
                engagementDetailSection
                    .transition(.opacity)
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
                .stroke(Color.havenPurple, lineWidth: 2.0)
        )
        .shadow(color: Color.havenPurple.opacity(0.35), radius: 8)
        .id(focusedNote.id)
        .padding(.horizontal, 16)
    }
    
    private func threadSection(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(dynamicParents) { parent in
                let parentProfile = nostrService.profiles[parent.pubkey]
                let rowData = FeedNoteRowData.resolve(
                    for: parent,
                    feedService: feedService,
                    nostrService: nostrService
                )
                FeedNoteRow(
                    note: parent,
                    profile: parentProfile,
                    rowData: rowData,
                    onReply: {
                        composeContext = ComposeContext(replyTo: parent, quoteTo: nil)
                    },
                    onQuote: {
                        composeContext = ComposeContext(replyTo: nil, quoteTo: parent)
                    },
                    onProfile: { pubkey in
                        showingProfilePubkey = pubkey
                    },
                    onMedia: { url in
                        showingMediaUrl = IdentifiableURL(url: url)
                    },
                    showParent: false,
                    layoutMode: .wide,
                    isFocused: parent.id == focusedNoteId
                )
                .id(parent.id)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectAndScrollToNote(parent.id, proxy: proxy)
                }
                .padding(.horizontal, 16)

                // Expanded engagement for parent notes
                if expandedEngagement && parent.id != focusedNoteId {
                    ThreadNoteEngagementRow(
                        reactions: groupedReactionsForNote(parent.id),
                        zapCount: zapTotalForNote(parent.id).count,
                        zapSats: zapTotalForNote(parent.id).sats,
                        repostCount: repostCountForNote(parent.id)
                    )
                    .padding(.horizontal, 20)
                }
            }

            if isLoadingParents {
                FeedNoteSkeletonRow()
                    .padding(.horizontal, 16)
            }
        }
    }

    private func repliesSection(proxy: ScrollViewProxy) -> some View {
        let currentReplies = dynamicReplies

        return VStack(alignment: .leading, spacing: 12) {
            if isLoadingReplies {
                // Subtle loading indicator — replies are being buffered
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.havenPurple)
                    Text("Loading replies\u{2026}")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .transition(.opacity)
            } else if currentReplies.isEmpty {
                Text("No replies yet")
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                    .transition(.opacity)
            } else {
                Text("Replies")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .padding(.bottom, 2)
                    .padding(.horizontal, 16)

                ForEach(currentReplies) { reply in
                    ThreadedReplyNode(
                        reply: reply,
                        allNotes: feedService.notes,
                        depth: 1,
                        onReply: { target in
                            composeContext = ComposeContext(replyTo: target, quoteTo: nil)
                        },
                        onQuote: { target in
                            composeContext = ComposeContext(replyTo: nil, quoteTo: target)
                        },
                        onProfile: { pubkey in
                            showingProfilePubkey = pubkey
                        },
                        onMedia: { url in
                            showingMediaUrl = IdentifiableURL(url: url)
                        },
                        focusedNoteId: $focusedNoteId,
                        proxy: proxy,
                        expandedEngagement: expandedEngagement,
                        perNoteReactions: perNoteReactions,
                        perNoteReposts: perNoteReposts,
                        perNoteZaps: perNoteZaps
                    )
                    .padding(.horizontal, 16)
                }
                .transition(.opacity)
            }
        }
    }
    
    @ViewBuilder
    private func mediaCarousel(urls: [URL]) -> some View {
        if urls.isEmpty {
            EmptyView()
        } else if urls.count == 1 {
            FeedMediaView(
                url: urls[0],
                onTap: { showingMediaUrl = IdentifiableURL(url: urls[0]) },
                maxHeight: 400,
                isThumbnail: false
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        } else {
            TabView {
                ForEach(urls, id: \.absoluteString) { url in
                    FeedMediaView(
                        url: url,
                        onTap: { showingMediaUrl = IdentifiableURL(url: url) },
                        maxHeight: 400,
                        isThumbnail: false
                    )
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .mediaTabViewStyleCompat()
            .frame(height: 400)
            .padding(.top, 4)
        }
    }

    private func actionButton(icon: String, color: Color = .secondary, count: Int?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(color)
                if let count = count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(color)
                }
            }
            .frame(height: 32)
            .padding(.horizontal, (count ?? 0) > 0 ? 10 : 0)
            .frame(minWidth: 32)
            .background(color.opacity(color == .secondary ? 0.1 : 0.15))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    
    private func fetchReplies() {
        guard !isLoadingReplies else { return }
        isLoadingReplies = true

        // Try local relay AND external relays to find replies
        var relayURLs: [URL] = [URL(string: configService.config.nostrURL)!]
        let externalStrs = configService.config.feedRelays.isEmpty ? [
            "wss://relay.damus.io",
            "wss://relay.primal.net",
            "wss://nos.lol",
        ] : configService.config.feedRelays
        relayURLs.append(contentsOf: externalStrs.compactMap { URL(string: $0) })

        let subId = "replies-\(UUID().uuidString.prefix(8))"
        var activeClients: [WebSocketClient] = []

        for url in relayURLs {
            let client = WebSocketClient()
            client.isTemporary = true // Clean up when done
            activeClients.append(client)

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { msg in
                    self.handleReplyMessage(msg, client: client)
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        let targetRootId = self.threadRootId
                        let activeFocusId = self.focusedNoteId.isEmpty ? self.note.id : self.focusedNoteId
                        
                        let repliesFilter: [String: Any] = ["kinds": [1], "#e": [targetRootId], "limit": 150]
                        let engagementFilter: [String: Any] = ["kinds": [6, 7, 9735], "#e": [activeFocusId], "limit": 150]
                        let req = ["REQ", subId, repliesFilter, engagementFilter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
        }
        
        // Auto-disconnect and flush any remaining buffered replies after 6 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            for client in activeClients {
                client.disconnect()
            }
            if self.isLoadingReplies {
                self.flushPendingReplies()
            }
        }
    }

    private func handleReplyMessage(_ msg: String, client: WebSocketClient) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String else { return }

        if type == "EVENT", json.count >= 3,
           let ev = json[2] as? [String: Any],
           let id = ev["id"] as? String,
           let pubkey = ev["pubkey"] as? String,
           let content = ev["content"] as? String,
           let createdAt = ev["created_at"] as? Int64,
           let kind = ev["kind"] as? Int,
           let tags = ev["tags"] as? [[String]] {

            if kind == 1 {
                let reply = FeedNote(
                    id: id,
                    pubkey: pubkey,
                    content: content,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                    tags: tags,
                    kind: kind
                )

                if !FeedNote.isNoiseOrSpam(content: content, tags: tags) {
                    if isLoadingReplies {
                        // Buffer while loading — all revealed at once on EOSE
                        if !pendingReplies.contains(where: { $0.id == id }) {
                            pendingReplies.append(reply)
                        }
                    } else {
                        // Already revealed — late arrivals added directly
                        if feedService.findNote(id: id) == nil {
                            feedService.addNote(reply)
                        }
                    }

                    // Pre-fetch profile so it's ready by reveal time
                    if nostrService.profiles[pubkey] == nil {
                        nostrService.fetchMissingProfiles(for: [pubkey])
                    }
                }
            } else if kind == 7 {
                if !self.detailedReactions.contains(where: { $0.id == id }) {
                    if let evData = try? JSONSerialization.data(withJSONObject: ev),
                       let event = try? JSONDecoder().decode(NostrEvent.self, from: evData) {
                        self.detailedReactions.append(event)
                        if nostrService.profiles[pubkey] == nil {
                            nostrService.fetchMissingProfiles(for: [pubkey])
                        }
                    }
                }
            } else if kind == 6 {
                if !self.detailedReposts.contains(where: { $0.id == id }) {
                    if let evData = try? JSONSerialization.data(withJSONObject: ev),
                       let event = try? JSONDecoder().decode(NostrEvent.self, from: evData) {
                        self.detailedReposts.append(event)
                        if nostrService.profiles[pubkey] == nil {
                            nostrService.fetchMissingProfiles(for: [pubkey])
                        }
                    }
                }
            } else if kind == 9735 {
                if !self.detailedZaps.contains(where: { $0.id == id }) {
                    if let evData = try? JSONSerialization.data(withJSONObject: ev),
                       let event = try? JSONDecoder().decode(NostrEvent.self, from: evData) {
                        self.detailedZaps.append(event)
                        if let descJson = event.tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
                           let descData = descJson.data(using: .utf8),
                           let zapReq = try? JSONSerialization.jsonObject(with: descData) as? [String: Any],
                           let senderPubkey = zapReq["pubkey"] as? String {
                            if nostrService.profiles[senderPubkey] == nil {
                                nostrService.fetchMissingProfiles(for: [senderPubkey])
                            }
                        }
                    }
                }
            }
        } else if type == "EOSE" {
            client.disconnect()
            if isLoadingReplies {
                flushPendingReplies()
            }
        }
    }

    private func flushPendingReplies() {
        // Add all buffered replies to feedService at once
        for reply in pendingReplies {
            if feedService.findNote(id: reply.id) == nil {
                feedService.addNote(reply)
            }
        }
        pendingReplies.removeAll()

        withAnimation(.easeIn(duration: 0.25)) {
            isLoadingReplies = false
        }
    }

    private func fetchEngagement(for eventId: String) {
        // Clear previous reactions to prevent flash of wrong data
        detailedReactions.removeAll()
        detailedReposts.removeAll()
        detailedZaps.removeAll()

        var relayURLs: [URL] = [URL(string: configService.config.nostrURL)!]
        let externalStrs = configService.config.feedRelays.isEmpty ? [
            "wss://relay.damus.io",
            "wss://relay.primal.net",
            "wss://nos.lol",
        ] : configService.config.feedRelays
        relayURLs.append(contentsOf: externalStrs.compactMap { URL(string: $0) })

        let subId = "eng-\(eventId.prefix(6))-\(UUID().uuidString.prefix(4))"
        
        for url in relayURLs {
            let client = WebSocketClient()
            client.isTemporary = true

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { msg in
                    self.handleReplyMessage(msg, client: client)
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        let filter: [String: Any] = ["kinds": [6, 7, 9735], "#e": [eventId], "limit": 100]
                        let req = ["REQ", subId, filter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                client.disconnect()
            }
        }
    }

    // MARK: - Expanded Thread Engagement

    /// All note IDs in the current thread (parents + focused + all replies).
    private var allThreadNoteIds: Set<String> {
        var ids = Set(dynamicParents.map(\.id))
        ids.insert(focusedNote.id)
        // BFS to collect all reply IDs
        var queue = [focusedNote.id]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            let children = feedService.notes.filter { $0.parentEventId == current }
            for child in children {
                if ids.insert(child.id).inserted {
                    queue.append(child.id)
                }
            }
        }
        return ids
    }

    private func fetchAllThreadEngagement() {
        let noteIds = Array(allThreadNoteIds)
        guard !noteIds.isEmpty else { return }
        isLoadingExpandedEngagement = true

        var relayURLs: [URL] = [URL(string: configService.config.nostrURL)!]
        let externalStrs = configService.config.feedRelays.isEmpty ? [
            "wss://relay.damus.io",
            "wss://relay.primal.net",
            "wss://nos.lol",
        ] : configService.config.feedRelays
        relayURLs.append(contentsOf: externalStrs.compactMap { URL(string: $0) })

        let subId = "thread-eng-\(UUID().uuidString.prefix(6))"

        for url in relayURLs {
            let client = WebSocketClient()
            client.isTemporary = true
            let threadIds = Set(noteIds)

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { msg in
                    self.handleExpandedEngagementMessage(msg, threadIds: threadIds, client: client)
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        let filter: [String: Any] = ["kinds": [6, 7, 9735], "#e": noteIds, "limit": 500]
                        let req = ["REQ", subId, filter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)

            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                client.disconnect()
                if self.isLoadingExpandedEngagement {
                    self.isLoadingExpandedEngagement = false
                }
            }
        }
    }

    private func handleExpandedEngagementMessage(_ msg: String, threadIds: Set<String>, client: WebSocketClient) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String else { return }

        if type == "EVENT", json.count >= 3,
           let ev = json[2] as? [String: Any],
           let id = ev["id"] as? String,
           let pubkey = ev["pubkey"] as? String,
           let kind = ev["kind"] as? Int,
           let tags = ev["tags"] as? [[String]] {

            // Find which thread note this engagement targets (last matching e-tag per NIP-25)
            let eTags = tags.filter { $0.count >= 2 && $0[0] == "e" }
            guard let targetNoteId = eTags.last(where: { threadIds.contains($0[1]) })?[1] else { return }

            guard let evData = try? JSONSerialization.data(withJSONObject: ev),
                  let event = try? JSONDecoder().decode(NostrEvent.self, from: evData) else { return }

            if kind == 7 {
                if !(perNoteReactions[targetNoteId]?.contains(where: { $0.id == id }) ?? false) {
                    perNoteReactions[targetNoteId, default: []].append(event)
                }
            } else if kind == 6 {
                if !(perNoteReposts[targetNoteId]?.contains(where: { $0.id == id }) ?? false) {
                    perNoteReposts[targetNoteId, default: []].append(event)
                }
            } else if kind == 9735 {
                if !(perNoteZaps[targetNoteId]?.contains(where: { $0.id == id }) ?? false) {
                    perNoteZaps[targetNoteId, default: []].append(event)
                }
            }

            if nostrService.profiles[pubkey] == nil {
                nostrService.fetchMissingProfiles(for: [pubkey])
            }
            // For zaps, also fetch the sender profile
            if kind == 9735,
               let descJson = tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
               let descData = descJson.data(using: .utf8),
               let zapReq = try? JSONSerialization.jsonObject(with: descData) as? [String: Any],
               let senderPubkey = zapReq["pubkey"] as? String,
               nostrService.profiles[senderPubkey] == nil {
                nostrService.fetchMissingProfiles(for: [senderPubkey])
            }
        } else if type == "EOSE" {
            client.disconnect()
            isLoadingExpandedEngagement = false
        }
    }

    // MARK: - Per-Note Engagement Helpers

    private func groupedReactionsForNote(_ noteId: String) -> [(emoji: String, count: Int)] {
        let reactions = perNoteReactions[noteId] ?? []
        var groups: [String: Int] = [:]
        for rx in reactions {
            let emoji = (rx.content == "+" || rx.content.isEmpty) ? "❤️" : rx.content
            guard emoji.count <= 4 else { continue }
            groups[emoji, default: 0] += 1
        }
        return groups.map { (emoji: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    private func zapTotalForNote(_ noteId: String) -> (count: Int, sats: Int64) {
        let zaps = perNoteZaps[noteId] ?? []
        var totalSats: Int64 = 0
        for zap in zaps {
            if let descJson = zap.tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
               let descData = descJson.data(using: .utf8),
               let zapReq = try? JSONSerialization.jsonObject(with: descData) as? [String: Any],
               let reqTags = zapReq["tags"] as? [[String]],
               let amountTag = reqTags.first(where: { $0.count >= 2 && $0[0] == "amount" }),
               let msats = Int64(amountTag[1]) {
                totalSats += msats / 1000
            }
        }
        return (count: zaps.count, sats: totalSats)
    }

    private func repostCountForNote(_ noteId: String) -> Int {
        Set((perNoteReposts[noteId] ?? []).map(\.pubkey)).count
    }

    private func likeNote() {
        let noteId = note.id
        if feedService.likedEventIds.contains(noteId) {
            UnlikeNotificationManager.shared.startCountdown {
                self.feedService.likedEventIds.remove(noteId)
                var stats = self.feedService.noteStats[noteId] ?? NoteStats(replies: 0, reactions: 0, reposts: 0)
                stats.reactions = max(0, stats.reactions - 1)
                self.feedService.noteStats[noteId] = stats
                self.feedService.saveInteractionState()
            }
            return
        }
        feedService.likedEventIds.insert(noteId)
        var currentStats = feedService.noteStats[noteId] ?? NoteStats(replies: 0, reactions: 0, reposts: 0)
        currentStats.reactions += 1
        feedService.noteStats[noteId] = currentStats
        feedService.saveInteractionState()
        let relayHint = ConfigService.shared.config.nostrURL
        Task {
            guard let signed = await nostrService.signEventAsync(kind: 7, content: "+", tags: [["e", noteId, relayHint], ["p", note.pubkey], ["k", String(note.kind)]]) else { return }
            nostrService.postEvent(signed)
        }
    }

    private func reactToNote(with emoji: String) {
        if !feedService.likedEventIds.contains(note.id) {
            feedService.likedEventIds.insert(note.id)

            // Proactively update stats locally
            var currentStats = feedService.noteStats[note.id] ?? NoteStats(replies: 0, reactions: 0, reposts: 0)
            currentStats.reactions += 1
            feedService.noteStats[note.id] = currentStats

            feedService.saveInteractionState()
        }
        let relayHint = ConfigService.shared.config.nostrURL
        Task {
            guard let signed = await nostrService.signEventAsync(kind: 7, content: emoji, tags: [["e", note.id, relayHint], ["p", note.pubkey], ["k", String(note.kind)]]) else { return }
            nostrService.postEvent(signed)
        }
    }
    
    private func blockUser(hexPubkey: String) {
        guard let data = Bech32.hexToData(hexPubkey),
              let npub = Bech32.encode(hrp: "npub", data: data) else { return }
        configService.blockProfile(npub)
        nostrService.objectWillChange.send()
        presentationMode.wrappedValue.dismiss()
    }
    
    private func repostNote() {
        PendingPostManager.shared.startRepost(sourceNote: note, nostrService: nostrService)
    }

    private func getLightingAddress(for pubkey: String) -> String? {
        if let profile = nostrService.profiles[pubkey] {
            if let lud06 = profile.lud06, !lud06.isEmpty { return "lnurl:" + lud06 }
            if let lud16 = profile.lud16, !lud16.isEmpty { return lud16 }
            // NIP-05 resolves to /.well-known/nostr.json — a completely different endpoint
            // from the LUD-16 /.well-known/lnurlp/ path. Do NOT use NIP-05 as a lightning address.
        }
        return nil
    }
    
    private func zapNote(lud16: String, amount: Int? = nil) async {
        let amountSats = amount ?? (ConfigService.shared.config.defaultZapAmount / 1000)

        do {
            try await ZapService.shared.zapNote(
                noteId: note.id,
                notePubkey: note.pubkey,
                lud16: lud16,
                amountSats: amountSats
            )
            await MainActor.run {
                feedService.zappedEventIds[note.id] = amountSats
                feedService.saveInteractionState()
            }
            // Re-fetch engagement after a delay so the zap receipt has time to propagate
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                fetchEngagement(for: note.id)
            }
        } catch {
            print("Zap failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Thread Loading

    private func fetchParents() {
        // NIP-10: A reply note includes e-tags for all thread ancestors.
        // Extract ALL ancestor IDs and fetch them in a single batch request
        // instead of chasing parents one-by-one with sequential round-trips.
        let ancestorIds = note.tags
            .filter { $0.count >= 2 && $0[0] == "e" }
            .filter { tag in
                // Skip explicitly-marked mentions (not thread ancestors)
                if tag.count >= 4 && tag[3] == "mention" { return false }
                return true
            }
            .map { $0[1] }

        guard !ancestorIds.isEmpty, !isLoadingParents else { return }
        isLoadingParents = true

        var relayURLs: [URL] = [URL(string: configService.config.nostrURL)!]
        let externalStrs = configService.config.feedRelays.isEmpty ? [
            "wss://relay.damus.io",
            "wss://relay.primal.net",
            "wss://nos.lol",
        ] : configService.config.feedRelays
        relayURLs.append(contentsOf: externalStrs.compactMap { URL(string: $0) })

        let subId = "thread-\(UUID().uuidString.prefix(8))"

        for url in relayURLs {
            let client = WebSocketClient()
            client.isTemporary = true

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { msg in
                    self.handleParentMessage(msg, client: client)
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        // Single batch request for ALL ancestors at once
                        let filter: [String: Any] = ["ids": ancestorIds, "limit": 50]
                        let req = ["REQ", subId, filter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)

            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                client.disconnect()
                if self.isLoadingParents {
                    withAnimation(.easeIn(duration: 0.25)) {
                        self.isLoadingParents = false
                    }
                }
            }
        }
    }

    private func handleParentMessage(_ msg: String, client: WebSocketClient) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String else { return }

        if type == "EVENT", json.count >= 3,
           let ev = json[2] as? [String: Any],
           let id = ev["id"] as? String,
           let pubkey = ev["pubkey"] as? String,
           let content = ev["content"] as? String,
           let createdAt = ev["created_at"] as? Int64,
           let kind = ev["kind"] as? Int,
           let tags = ev["tags"] as? [[String]] {

            let parent = FeedNote(
                id: id,
                pubkey: pubkey,
                content: content,
                createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                tags: tags,
                kind: kind
            )

            if !parentNotes.contains(where: { $0.id == id }) {
                parentNotes.append(parent)
                parentNotes.sort { $0.createdAt < $1.createdAt }
            }

            if nostrService.profiles[pubkey] == nil {
                nostrService.fetchMissingProfiles(for: [pubkey])
            }
        } else if type == "EOSE" {
            client.disconnect()
            withAnimation(.easeIn(duration: 0.25)) {
                isLoadingParents = false
            }
        }
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

    // MARK: - Rich Engagement Computations

    private var groupedReactions: [(emoji: String, count: Int, reactorPubkeys: [String])] {
        var groups: [String: [String]] = [:]
        for rx in detailedReactions {
            let emoji = (rx.content == "+" || rx.content.isEmpty) ? "❤️" : rx.content
            guard emoji.count <= 4 else { continue }
            groups[emoji, default: []].append(rx.pubkey)
        }
        return groups.map { (emoji: $0.key, count: $0.value.count, reactorPubkeys: $0.value) }
            .sorted { $0.count > $1.count }
    }

    struct ZapDetail: Hashable {
        let id: String
        let zapperPubkey: String
        let amountSats: Int64
        let comment: String
    }

    private var parsedZaps: [ZapDetail] {
        var list: [ZapDetail] = []
        for zap in detailedZaps {
            guard let descJson = zap.tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
                  let descData = descJson.data(using: .utf8),
                  let zapReq = try? JSONSerialization.jsonObject(with: descData) as? [String: Any],
                  let senderPubkey = zapReq["pubkey"] as? String else { continue }
            
            var amountSats: Int64 = 0
            if let reqTags = zapReq["tags"] as? [[String]],
               let amountTag = reqTags.first(where: { $0.count >= 2 && $0[0] == "amount" }),
               let msats = Int64(amountTag[1]) {
                amountSats = msats / 1000
            }
            let comment = zapReq["content"] as? String ?? ""
            list.append(ZapDetail(id: zap.id, zapperPubkey: senderPubkey, amountSats: amountSats, comment: comment))
        }
        return list.sorted { $0.amountSats > $1.amountSats }
    }

    private var totalZappedSats: Int64 {
        parsedZaps.reduce(0) { $0 + $1.amountSats }
    }

    private var reactorsMapped: [(pubkey: String, emoji: String)] {
        detailedReactions.map { (pubkey: $0.pubkey, emoji: ($0.content == "+" || $0.content.isEmpty) ? "❤️" : $0.content) }
    }

    private var repostersMapped: [String] {
        Array(Set(detailedReposts.map { $0.pubkey }))
    }

    // MARK: - Engagement Panel View

    @ViewBuilder
    private var engagementDetailSection: some View {
        // Thin separator between note content and engagement
        Rectangle()
            .fill(Color.havenPurple.opacity(0.15))
            .frame(height: 0.5)
            .padding(.top, 10)

        // Compact inline engagement row
        HStack(spacing: 12) {
            // Reactions — tappable pill list
            if !groupedReactions.isEmpty {
                Button {
                    showingReactorsSheet = true
                } label: {
                    HStack(spacing: 4) {
                        ForEach(groupedReactions.prefix(4), id: \.emoji) { group in
                            HStack(spacing: 2) {
                                Text(group.emoji)
                                    .font(.system(size: 12))
                                Text("\(group.count)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        if groupedReactions.count > 4 {
                            Text("+\(groupedReactions.count - 4)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            // Zaps — compact
            if !parsedZaps.isEmpty {
                Button {
                    showingZappersSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.orange)
                        Text(compactZapText)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            // Reposts — compact
            if !detailedReposts.isEmpty {
                Button {
                    showingRepostersSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.2.squarepath")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.green)
                        Text("\(repostersMapped.count)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.top, 8)
    }

    private var compactZapText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let totalStr = formatter.string(from: NSNumber(value: totalZappedSats)) ?? "\(totalZappedSats)"
        return "\(parsedZaps.count) · \(totalStr)"
    }

}

// MARK: - ZappersListView

struct ZappersListView: View {
    let zaps: [NoteDetailView.ZapDetail]
    var onDismiss: (() -> Void)? = nil
    @EnvironmentObject var nostrService: NostrService
    @Environment(\.presentationMode) var presentationMode
    @State private var selectedProfilePubkey: String?

    var body: some View {
        NavigationView {
            List(zaps, id: \.id) { zap in
                let profile = nostrService.profiles[zap.zapperPubkey]
                Button {
                    selectedProfilePubkey = zap.zapperPubkey
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(url: profile?.pictureURL, pubkey: zap.zapperPubkey, size: 40)
                            .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 2))
                            .shadow(color: Color.black.opacity(0.1), radius: 3)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(profile?.bestName ?? "npub…" + String(zap.zapperPubkey.suffix(6)))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.primary)
                                Spacer()
                                Text("\(zap.amountSats) sats")
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundColor(.orange)
                            }
                            if !zap.comment.isEmpty {
                                Text(zap.comment)
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
            .navigationTitle("Zaps")
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

// MARK: - Thread Note Engagement Row (reusable compact row for expanded view)

struct ThreadNoteEngagementRow: View {
    let reactions: [(emoji: String, count: Int)]
    let zapCount: Int
    let zapSats: Int64
    let repostCount: Int

    private var hasContent: Bool {
        !reactions.isEmpty || zapCount > 0 || repostCount > 0
    }

    var body: some View {
        if hasContent {
            HStack(spacing: 8) {
                if !reactions.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(reactions.prefix(3), id: \.emoji) { group in
                            HStack(spacing: 1) {
                                Text(group.emoji).font(.system(size: 11))
                                Text("\(group.count)")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        if reactions.count > 3 {
                            Text("+\(reactions.count - 3)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(6)
                }

                if zapCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.orange)
                        Text(formatSats(zapSats))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(6)
                }

                if repostCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.2.squarepath")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.green)
                        Text("\(repostCount)")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(6)
                }

                Spacer()
            }
            .padding(.top, 4)
        }
    }

    private func formatSats(_ sats: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: sats)) ?? "\(sats)"
    }
}

// MARK: - ThreadedReplyNode

struct ThreadedReplyNode: View {
    let reply: FeedNote
    let allNotes: [FeedNote]
    let depth: Int
    var onReply: ((FeedNote) -> Void)? = nil
    var onQuote: ((FeedNote) -> Void)? = nil
    var onProfile: ((String) -> Void)? = nil
    var onMedia: ((URL) -> Void)? = nil
    @Binding var focusedNoteId: String
    let proxy: ScrollViewProxy

    // Expanded engagement data
    var expandedEngagement: Bool = false
    var perNoteReactions: [String: [NostrEvent]] = [:]
    var perNoteReposts: [String: [NostrEvent]] = [:]
    var perNoteZaps: [String: [NostrEvent]] = [:]

    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService

    var body: some View {
        let childReplies = allNotes.filter { $0.parentEventId == reply.id }
            .sorted(by: { $0.createdAt < $1.createdAt })

        let isCurrentFocused = reply.id == focusedNoteId

        VStack(alignment: .leading, spacing: 8) {
            let replyProfile = nostrService.profiles[reply.pubkey]
            let rowData = FeedNoteRowData.resolve(
                for: reply,
                feedService: FeedService.shared,
                nostrService: nostrService
            )
            FeedNoteRow(
                note: reply,
                profile: replyProfile,
                rowData: rowData,
                onReply: { onReply?(reply) },
                onQuote: { onQuote?(reply) },
                onProfile: onProfile,
                onMedia: onMedia,
                showParent: false,
                layoutMode: .wide,
                isFocused: isCurrentFocused
            )
            .id(reply.id)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                    focusedNoteId = reply.id
                    proxy.scrollTo(reply.id, anchor: .center)
                }
            }

            // Expanded engagement for this reply
            if expandedEngagement && !isCurrentFocused {
                ThreadNoteEngagementRow(
                    reactions: groupedReactionsForReply(reply.id),
                    zapCount: zapTotalForReply(reply.id).count,
                    zapSats: zapTotalForReply(reply.id).sats,
                    repostCount: repostCountForReply(reply.id)
                )
                .padding(.horizontal, 4)
            }

            if !childReplies.isEmpty {
                if depth >= 3 {
                    // Prevent excessive indentation squishing on narrow mobile screens
                    Button {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                            focusedNoteId = reply.id
                            proxy.scrollTo(reply.id, anchor: .center)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 11, weight: .bold))
                            Text("Show \(childReplies.count) more \(childReplies.count == 1 ? "reply" : "replies")")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(Color.havenPurple)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(Color.havenPurple.opacity(0.1))
                        .cornerRadius(8)
                        .padding(.leading, 8)
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        // Thread vertical connecting line
                        Rectangle()
                            .fill(Color.havenPurple.opacity(0.25))
                            .frame(width: 1.5)
                            .padding(.leading, 8)
                            .padding(.trailing, 6)
                            .padding(.vertical, 2)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(childReplies) { child in
                                ThreadedReplyNode(
                                    reply: child,
                                    allNotes: allNotes,
                                    depth: depth + 1,
                                    onReply: onReply,
                                    onQuote: onQuote,
                                    onProfile: onProfile,
                                    onMedia: onMedia,
                                    focusedNoteId: $focusedNoteId,
                                    proxy: proxy,
                                    expandedEngagement: expandedEngagement,
                                    perNoteReactions: perNoteReactions,
                                    perNoteReposts: perNoteReposts,
                                    perNoteZaps: perNoteZaps
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // Per-note engagement helpers for this reply node
    private func groupedReactionsForReply(_ noteId: String) -> [(emoji: String, count: Int)] {
        let reactions = perNoteReactions[noteId] ?? []
        var groups: [String: Int] = [:]
        for rx in reactions {
            let emoji = (rx.content == "+" || rx.content.isEmpty) ? "❤️" : rx.content
            guard emoji.count <= 4 else { continue }
            groups[emoji, default: 0] += 1
        }
        return groups.map { (emoji: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }

    private func zapTotalForReply(_ noteId: String) -> (count: Int, sats: Int64) {
        let zaps = perNoteZaps[noteId] ?? []
        var totalSats: Int64 = 0
        for zap in zaps {
            if let descJson = zap.tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
               let descData = descJson.data(using: .utf8),
               let zapReq = try? JSONSerialization.jsonObject(with: descData) as? [String: Any],
               let reqTags = zapReq["tags"] as? [[String]],
               let amountTag = reqTags.first(where: { $0.count >= 2 && $0[0] == "amount" }),
               let msats = Int64(amountTag[1]) {
                totalSats += msats / 1000
            }
        }
        return (count: zaps.count, sats: totalSats)
    }

    private func repostCountForReply(_ noteId: String) -> Int {
        Set((perNoteReposts[noteId] ?? []).map(\.pubkey)).count
    }
}

// MARK: - NoteDetailViewWrapper

struct NoteDetailViewWrapper: View {
    let noteId: String
    var onDismiss: (() -> Void)? = nil
    @State private var resolvedNote: FeedNote?
    @State private var isLoading = true
    @State private var error: String?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @StateObject private var feedService = FeedService.shared
    @State private var cancellables = Set<AnyCancellable>()

    var body: some View {
        NavigationStack {
            Group {
                if let note = resolvedNote {
                    NoteDetailView(note: note)
                } else if isLoading {
                    VStack {
                        ProgressView()
                        Text("Fetching note...")
                            .foregroundColor(.secondary)
                            .padding()
                    }
                } else if let error = error {
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                        Text(error)
                            .padding()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        if let onDismiss = onDismiss {
                            onDismiss()
                        } else {
                            dismiss()
                        }
                    }
                }
            }
        }
        .onAppear {
            fetchNote()
        }
    }

    private func fetchNote() {
        if let existing = feedService.findNote(id: noteId) {
            self.resolvedNote = existing
            self.isLoading = false
            return
        }

        let hexId: String
        if noteId.hasPrefix("note1") {
            hexId = Bech32.decode(noteId)?.hexString ?? noteId
        } else if noteId.hasPrefix("nevent1") {
            hexId = noteId // Simplified
        } else {
            hexId = noteId
        }

        let relays = [URL(string: configService.config.nostrURL)!] + 
                     [URL(string: "wss://relay.damus.io")!, URL(string: "wss://relay.primal.net")!]

        for url in relays {
            let client = WebSocketClient()
            client.isTemporary = true
            
            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { msg in
                    self.handleNoteMessage(msg, client: client)
                }
                .store(in: &cancellables)
                
            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        let filter: [String: Any] = ["ids": [hexId], "limit": 1]
                        let req = ["REQ", "load-\(UUID().uuidString.prefix(8))", filter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                    }
                }
                .store(in: &cancellables)
            
            client.connect(url: url)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if self.isLoading {
                self.isLoading = false
                if self.resolvedNote == nil {
                    self.error = "Could not find note"
                }
            }
        }
    }

    private func handleNoteMessage(_ msg: String, client: WebSocketClient) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String, type == "EVENT",
              let ev = json[2] as? [String: Any],
              let id = ev["id"] as? String,
              let pubkey = ev["pubkey"] as? String,
              let content = ev["content"] as? String,
              let createdAt = ev["created_at"] as? Int64,
              let kind = ev["kind"] as? Int,
              let tags = ev["tags"] as? [[String]] else { return }

        let note = FeedNote(
            id: id,
            pubkey: pubkey,
            content: content,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            tags: tags,
            kind: kind
        )
        
        DispatchQueue.main.async {
            self.resolvedNote = note
            self.isLoading = false
            client.disconnect()
        }
    }
}
