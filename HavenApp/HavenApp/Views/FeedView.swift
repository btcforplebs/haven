import SwiftUI
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

struct IdentifiableString: Identifiable {
    let id: String
}


private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - FeedView

struct FeedView: View {
    @StateObject private var feedService = FeedService.shared
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @ObservedObject private var pendingManager = PendingPostManager.shared
    @State private var composeContext: ComposeContext?
    @State private var showingRelayStatus = false
    @State private var showingNoteId: String?
    @State private var showingProfileKey: IdentifiableString?
    @State private var showingMediaUrl: IdentifiableURL?
    @State private var selectedGridMediaNoteId: String?
    @State private var isShowingGridMediaViewer = false
    @State private var gridMediaSnapshot: [FeedNote] = []
    @State private var galleryDragOffset: CGSize = .zero
    @State private var isRefreshing = false
    @State private var showingGlobalMediaWarning = false
    @State private var isAtTop: Bool = true
    @State private var scrolledNoteID: String?
    @State private var navigationPath = NavigationPath()
    /// Debounce work item for auto-loading pending notes so overlapping
    /// onChange triggers don't queue duplicate applyPendingNotes() calls.
    @State private var autoLoadWork: DispatchWorkItem?

    var body: some View {
        #if os(iOS)
        NavigationStack(path: $navigationPath) {
            rootContent
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: FeedNote.self) { note in
                    NoteDetailView(note: note)
                }
        }
        #else
        VStack(spacing: 0) {
            macFeedHeader
            Divider()
            rootContent
        }
        #endif
    }

    #if os(macOS)
    private var macFeedHeader: some View {
        HStack(spacing: 12) {
            // Connection dot
            Button(action: { showingRelayStatus = true }) {
                Circle()
                    .fill(feedService.connectionDotColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: feedService.connectionDotColor.opacity(0.8), radius: 3)
            }
            .buttonStyle(.plain)
            .help(String(localized: "feed.help.relayStatus"))
            .accessibilityLabel("Relay status")
            .accessibilityValue(feedService.connectionStatus)

            // Feed mode picker
            Menu {
                ForEach(FeedMode.allCases, id: \.self) { mode in
                    Button(action: { feedService.switchMode(mode) }) {
                        let displayName = mode == .discovery ? "Discover" : mode.rawValue
                        if feedService.feedMode == mode {
                            Label(displayName, systemImage: "checkmark")
                        } else {
                            Text(displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    let displayName = feedService.feedMode == .discovery ? "Discover" : feedService.feedMode.rawValue
                    Text(displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(.primary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            if feedService.feedMode == .media {
                Button(action: {
                    feedService.mediaFeedMode = .following
                    feedService.refresh()
                }) {
                    Image(systemName: feedService.mediaFeedMode == .following ? "person.2.fill" : "person.2")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(feedService.mediaFeedMode == .following ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "feed.help.followingMedia"))

                Button(action: {
                    showingGlobalMediaWarning = true
                }) {
                    Image(systemName: "globe")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(feedService.mediaFeedMode == .global ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "feed.help.globalMedia"))
            } else if feedService.feedMode == .popular {
                // My Follows filter
                Button(action: {
                    feedService.popularFilter = feedService.popularFilter == .follows ? .all : .follows
                    feedService.recomputeFilteredNotes()
                }) {
                    Image(systemName: feedService.popularFilter == .follows ? "person.2.fill" : "person.2")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(feedService.popularFilter == .follows ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help(feedService.popularFilter == .follows ? String(localized: "feed.help.showingFollowsOnly") : String(localized: "feed.help.filterToFollows"))

                // Non-Follows filter
                Button(action: {
                    feedService.popularFilter = feedService.popularFilter == .nonFollows ? .all : .nonFollows
                    feedService.recomputeFilteredNotes()
                }) {
                    Image(systemName: feedService.popularFilter == .nonFollows ? "globe.americas.fill" : "globe.americas")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(feedService.popularFilter == .nonFollows ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help(feedService.popularFilter == .nonFollows ? String(localized: "feed.help.showingNonFollowsOnly") : String(localized: "feed.help.filterToNonFollows"))

                // Engagement stats toggle
                Button(action: { feedService.showPopularEngagement.toggle() }) {
                    Image(systemName: feedService.showPopularEngagement ? "chart.bar.fill" : "chart.bar")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(feedService.showPopularEngagement ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help(feedService.showPopularEngagement ? String(localized: "feed.help.hideEngagementStats") : String(localized: "feed.help.showEngagementStats"))
            } else {
                // Auto-load new posts
                Button(action: { configService.config.autoLoadNewPosts.toggle(); configService.save() }) {
                    Image(systemName: configService.config.autoLoadNewPosts ? "bolt.circle.fill" : "bolt.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(configService.config.autoLoadNewPosts ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help(configService.config.autoLoadNewPosts ? String(localized: "feed.help.autoLoadOn") : String(localized: "feed.help.autoLoadOff"))

                // Reposts toggle
                Button(action: { configService.config.showReposts.toggle(); configService.save(); feedService.recomputeFilteredNotes() }) {
                    Image(systemName: "arrow.2.squarepath")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(configService.config.showReposts ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help(configService.config.showReposts ? String(localized: "feed.help.hideReposts") : String(localized: "feed.help.showReposts"))

                // Replies toggle
                Button(action: { configService.config.showReplies.toggle(); configService.save(); feedService.recomputeFilteredNotes() }) {
                    Image(systemName: configService.config.showReplies ? "message.fill" : "message")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(configService.config.showReplies ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help(configService.config.showReplies ? String(localized: "feed.help.hideReplies") : String(localized: "feed.help.showReplies"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(red: 0.12, green: 0.12, blue: 0.16))
    }
    #endif

    @ViewBuilder
    private var rootContent: some View {
        ZStack {
            // Match the platform theme background
            Color(red: 0.08, green: 0.08, blue: 0.1).ignoresSafeArea()

            Group {
                // Only show the full-screen contact-loading spinner when there
                // are no cached notes to render. Once a snapshot has been
                // restored (or notes have streamed in), the background sync
                // is surfaced via the inline `syncingPill` instead.
                let showLoadingContacts = (feedService.feedMode == .following || (feedService.feedMode == .media && feedService.mediaFeedMode == .following)) && feedService.isLoadingContacts && feedService.notes.isEmpty
                let showEmptyState = (feedService.feedMode == .following || (feedService.feedMode == .media && feedService.mediaFeedMode == .following)) && feedService.followedPubkeys.isEmpty && !feedService.isLoadingFeed && !feedService.isLoadingContacts

                if showLoadingContacts {
                    loadingContactsView
                } else if feedService.feedMode == .discovery && feedService.isLoadingExtendedNetwork && feedService.notes.isEmpty {
                    loadingExtendedNetworkView
                } else if feedService.feedMode == .popular && feedService.isLoadingPopular && feedService.notes.isEmpty {
                    loadingPopularView
                } else if showEmptyState {
                    emptyStateView
                } else if feedService.feedMode == .discovery && feedService.extendedNetworkPubkeys.isEmpty && !feedService.isLoadingFeed && !feedService.isLoadingExtendedNetwork {
                    emptyDiscoveryStateView
                } else if feedService.feedMode == .popular && feedService.filteredNotes.isEmpty && !feedService.isLoadingFeed && !feedService.isLoadingPopular {
                    emptyPopularStateView
                } else {
                    feedList
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: configService.activeAccountHexPubkey)
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                HStack(spacing: 8) {
                    Button(action: { showingRelayStatus = true }) {
                        Circle()
                            .fill(feedService.connectionDotColor)
                            .frame(width: 12, height: 12)
                            .shadow(color: feedService.connectionDotColor.opacity(0.8), radius: 4)
                            .padding(8)
                            .background(Color.primary.opacity(0.08))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Menu {
                        ForEach(FeedMode.allCases, id: \.self) { mode in
                            Button(action: { feedService.switchMode(mode) }) {
                                let displayName = mode == .discovery ? "Discover" : mode.rawValue
                                if feedService.feedMode == mode {
                            Label(displayName, systemImage: "checkmark")
                        } else {
                            Text(displayName)
                        }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            let displayName = feedService.feedMode == .discovery ? "Discover" : feedService.feedMode.rawValue
                            Text(displayName)
                                .font(.system(size: 20, weight: .bold))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundColor(.white)
                    }
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    if feedService.feedMode == .media {
                        Button(action: {
                            feedService.mediaFeedMode = .following
                            feedService.refresh()
                        }) {
                            Image(systemName: feedService.mediaFeedMode == .following ? "person.2.fill" : "person.2")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(feedService.mediaFeedMode == .following ? Color.havenPurple : .secondary)
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            showingGlobalMediaWarning = true
                        }) {
                            Image(systemName: "globe")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(feedService.mediaFeedMode == .global ? Color.havenPurple : .secondary)
                        }
                        .buttonStyle(.plain)
                    } else if feedService.feedMode == .popular {
                        // My Follows filter
                        Button(action: {
                            feedService.popularFilter = feedService.popularFilter == .follows ? .all : .follows
                            feedService.recomputeFilteredNotes()
                        }) {
                            Image(systemName: feedService.popularFilter == .follows ? "person.2.fill" : "person.2")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(feedService.popularFilter == .follows ? Color.havenPurple : .secondary)
                        }
                        .buttonStyle(.plain)

                        // Non-Follows filter
                        Button(action: {
                            feedService.popularFilter = feedService.popularFilter == .nonFollows ? .all : .nonFollows
                            feedService.recomputeFilteredNotes()
                        }) {
                            Image(systemName: feedService.popularFilter == .nonFollows ? "globe.americas.fill" : "globe.americas")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(feedService.popularFilter == .nonFollows ? Color.havenPurple : .secondary)
                        }
                        .buttonStyle(.plain)

                        // Engagement stats toggle
                        Button(action: { feedService.showPopularEngagement.toggle() }) {
                            Image(systemName: feedService.showPopularEngagement ? "chart.bar.fill" : "chart.bar")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(feedService.showPopularEngagement ? Color.havenPurple : .secondary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        // Autoload new posts button
                        Button(action: { configService.config.autoLoadNewPosts.toggle(); configService.save() }) {
                            Image(systemName: configService.config.autoLoadNewPosts ? "bolt.circle.fill" : "bolt.circle")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(configService.config.autoLoadNewPosts ? Color.havenPurple : .secondary)
                        }
                        .buttonStyle(.plain)

                        // Reposts toggle button
                        Button(action: { configService.config.showReposts.toggle(); configService.save(); feedService.recomputeFilteredNotes() }) {
                            Image(systemName: "arrow.2.squarepath")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(configService.config.showReposts ? Color.havenPurple : .secondary)
                        }
                        .buttonStyle(.plain)

                        // Replies toggle button
                        Button(action: { configService.config.showReplies.toggle(); configService.save(); feedService.recomputeFilteredNotes() }) {
                            Image(systemName: configService.config.showReplies ? "message.fill" : "message")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(configService.config.showReplies ? Color.havenPurple : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        #endif
        .onAppear {
            feedService.markViewed()
            // Resume if previously paused (e.g. view disappeared while in menu bar).
            if feedService.isPaused {
                feedService.resumeFeed()
                return
            }
            // Start feed immediately when running, even if still booting.
            // localRelayURL returns nil during boot so no WebSocket errors occur;
            // external relays are contacted right away instead of waiting ~3 minutes.
            if feedService.notes.isEmpty && !feedService.isLoadingContacts {
                feedService.refresh()
            }
        }
        .onChange(of: relayManager.isRunning) { _, running in
            if running && !feedService.isPaused && feedService.notes.isEmpty && !feedService.isLoadingContacts && !feedService.isLoadingFeed {
                feedService.refresh()
            }
        }
        .onChange(of: relayManager.isBooting) { _, booting in
            // Once booting finishes, add the local relay to the existing feed
            // connections instead of tearing everything down and rebuilding.
            if !booting && relayManager.isRunning && !feedService.isPaused {
                feedService.addLocalRelayIfReady()
            }
        }
        .sheet(item: $composeContext) { ctx in
            ComposeView(onDismiss: { composeContext = nil }, replyTo: ctx.replyTo, quoteTo: ctx.quoteTo, initialContent: ctx.initialContent)
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .onChange(of: pendingManager.editRequest?.id) { _, _ in
            guard let req = pendingManager.editRequest else { return }
            composeContext = ComposeContext(replyTo: req.replyTo, quoteTo: req.quoteTo, initialContent: req.content)
            pendingManager.editRequest = nil
        }
        .sheet(isPresented: $showingRelayStatus) {
            FeedDashboardSheet(onDismiss: { showingRelayStatus = false })
                .environmentObject(relayManager)
                .environmentObject(configService)
                .environmentObject(nostrService)
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { showingNoteId.map { IdentifiableString(id: $0) } },
            set: { showingNoteId = $0?.id }
        )) { noteId in
            NoteDetailViewWrapper(noteId: noteId.id, onDismiss: { showingNoteId = nil })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(item: $showingProfileKey) { p in
            ProfileView(pubkey: p.id, onDismiss: { showingProfileKey = nil })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(item: $showingMediaUrl) { media in
            FeedMediaViewer(url: media.url, onDismiss: { showingMediaUrl = nil })
        }
        .sheet(isPresented: $isShowingGridMediaViewer) {
            ZStack {
                Color.black
                    .opacity(max(0.1, 1.0 - (abs(galleryDragOffset.height) / 500.0)))
                    .ignoresSafeArea()
                
                TabView(selection: $selectedGridMediaNoteId) {
                    ForEach(gridMediaSnapshot) { note in
                        if let firstMediaURL = note.mediaURLs.first {
                            FeedMediaViewer(url: firstMediaURL, enableDragDismiss: false, onDismiss: { isShowingGridMediaViewer = false })
                                .tag(note.id as String?)
                        }
                    }
                }
                .mediaTabViewStyleCompat()
                .offset(y: galleryDragOffset.height)
                .scaleEffect(max(0.8, 1.0 - (abs(galleryDragOffset.height) / 1000.0)))
                .gesture(
                    DragGesture()
                        .onChanged { gesture in
                            if abs(gesture.translation.height) > abs(gesture.translation.width) || galleryDragOffset.height != 0 {
                                galleryDragOffset = CGSize(width: 0, height: gesture.translation.height)
                            }
                        }
                        .onEnded { gesture in
                            if abs(galleryDragOffset.height) > 120 {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    isShowingGridMediaViewer = false
                                    galleryDragOffset = .zero
                                }
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                    galleryDragOffset = .zero
                                }
                            }
                        }
                )
            }
            .ignoresSafeArea()
            .onDisappear {
                selectedGridMediaNoteId = nil
            }
        }
        .alert(String(localized: "feed.alert.sensitiveContent.title"), isPresented: $showingGlobalMediaWarning) {
            Button(String(localized: "feed.alert.sensitiveContent.proceed"), role: .destructive) {
                feedService.mediaFeedMode = .global
                feedService.refresh()
            }
            Button(String(localized: "feed.alert.sensitiveContent.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "feed.alert.sensitiveContent.message"))
        }
    }

    // MARK: - Loading Contacts

    private var loadingContactsView: some View {
        VStack(spacing: 32) {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.havenPurple)

                VStack(spacing: 8) {
                    Text(String(localized: "feed.loading.synchronizing"))
                        .font(.system(size: 18, weight: .bold, design: .default))
                        .tracking(0.3)
                    Text(String(localized: "feed.loading.fetchingFollows"))
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Text(String(localized: "feed.loading.patience"))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground)
    }

    private var loadingExtendedNetworkView: some View {
        VStack(spacing: 32) {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.havenPurple)

                VStack(spacing: 8) {
                    Text(String(localized: "feed.loading.analyzingNetwork"))
                        .font(.system(size: 18, weight: .bold, design: .default))
                        .tracking(0.3)
                    Text(String(localized: "feed.loading.findingConnections"))
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Text(String(localized: "feed.loading.patience"))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 40) {
            if relayManager.isBooting {
                // Relay is still starting up
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color.havenPurple)

                    VStack(spacing: 12) {
                        Text(String(localized: "feed.empty.relayStarting"))
                            .font(.system(size: 22, weight: .bold, design: .default))
                            .tracking(0.2)

                        Text(relayManager.bootStatusMessage.isEmpty ? String(localized: "feed.empty.initializingRelay") : relayManager.bootStatusMessage)
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                            .multilineTextAlignment(.center)
                    }
                }
            } else {
                // Relay is running but no follows
                VStack(spacing: 16) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 56, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    VStack(spacing: 12) {
                        Text(String(localized: "feed.empty.following.title"))
                            .font(.system(size: 22, weight: .bold, design: .default))
                            .tracking(0.2)

                        Text(String(localized: "feed.empty.following.subtitle"))
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                    }
                }

                Button {
                    feedService.refresh()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.clockwise")
                        Text(String(localized: "feed.action.refresh"))
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(max(16, min(48, 24))) // Adaptive padding
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground)
    }

    private var emptyDiscoveryStateView: some View {
        VStack(spacing: 40) {
            if relayManager.isBooting {
                // Relay is still starting up
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color.havenPurple)

                    VStack(spacing: 12) {
                        Text(String(localized: "feed.empty.relayStarting"))
                            .font(.system(size: 22, weight: .bold, design: .default))
                            .tracking(0.2)

                        Text(relayManager.bootStatusMessage.isEmpty ? String(localized: "feed.empty.initializingRelay") : relayManager.bootStatusMessage)
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                            .multilineTextAlignment(.center)
                    }
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.system(size: 56, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    VStack(spacing: 12) {
                        Text(String(localized: "feed.empty.discovery.title"))
                            .font(.system(size: 22, weight: .bold, design: .default))
                            .tracking(0.2)

                        Text(String(localized: "feed.empty.discovery.subtitle"))
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                            .multilineTextAlignment(.center)
                    }
                }

                Button {
                    feedService.refresh()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.clockwise")
                        Text(String(localized: "feed.action.refresh"))
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(max(16, min(48, 24))) // Adaptive padding
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground)
    }

    // MARK: - Popular Feed States

    private var loadingPopularView: some View {
        VStack(spacing: 32) {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.havenPurple)

                VStack(spacing: 8) {
                    Text(String(localized: "feed.loading.findingPopular"))
                        .font(.system(size: 18, weight: .bold, design: .default))
                        .tracking(0.3)
                    Text(String(localized: "feed.loading.scoringEngagement"))
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Text(String(localized: "feed.loading.analyzingReactions"))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground)
    }

    private var emptyPopularStateView: some View {
        VStack(spacing: 40) {
            VStack(spacing: 16) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 56, weight: .thin))
                    .foregroundStyle(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(spacing: 12) {
                    Text(String(localized: "feed.empty.popular.title"))
                        .font(.system(size: 22, weight: .bold, design: .default))
                        .tracking(0.2)

                    Text(String(localized: "feed.empty.popular.subtitle"))
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                        .tracking(0.3)
                        .multilineTextAlignment(.center)
                }
            }

            Button {
                feedService.refresh()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise")
                    Text(String(localized: "feed.action.refresh"))
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
        .padding(max(16, min(48, 24)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground)
    }

    // MARK: - Engagement Stats Badge

    @ViewBuilder
    private func engagementBadge(rank: Int, score: Double) -> some View {
        HStack(spacing: 6) {
            Text("#\(rank)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.havenPurple)
                .clipShape(Capsule())

            HStack(spacing: 3) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                Text(formatEngagementScore(score))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.havenPurple.opacity(0.3), lineWidth: 0.5)
        )
    }

    private func formatEngagementScore(_ score: Double) -> String {
        if score >= 1000 {
            return String(format: "%.1fk", score / 1000)
        }
        return String(format: "%.0f", score)
    }

    // MARK: - Auto-load debounce

    /// Schedules a debounced `applyPendingNotes()` call, cancelling any
    /// previously pending call so only one fires at a time.
    private func scheduleAutoLoad(delay: Double) {
        autoLoadWork?.cancel()
        let work = DispatchWorkItem { [self] in
            guard !feedService.pendingNotes.isEmpty,
                  configService.config.autoLoadNewPosts,
                  isAtTop else { return }
            feedService.applyPendingNotes()
        }
        autoLoadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Feed Actions (environment for FeedNoteRow)

    private var feedActionsValue: FeedActions {
        .make(feedService: feedService, nostrService: nostrService)
    }

    // MARK: - Feed List

    private var feedList: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(spacing: 0) {
                        // Anchor for scroll-to-top & scroll position tracking
                        Color.clear
                            .frame(height: 1)
                            .id("top")
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: ScrollOffsetPreferenceKey.self,
                                        value: geo.frame(in: .named("feedScroll")).minY
                                    )
                                }
                            )

                        if feedService.feedMode == .media {
                            mediaGridView
                        } else {
                            LazyVStack(spacing: 12) {

                        // Loading header
                        if feedService.isLoadingFeed && feedService.notes.isEmpty {
                            ForEach(0..<5, id: \.self) { _ in
                                FeedNoteSkeletonRow()
                                    .padding(.horizontal, 16)
                            }
                        }

                        ForEach(Array(feedService.filteredNotes.enumerated()), id: \.element.id) { index, note in
                            let profile = nostrService.profiles[note.pubkey]
                            let rowData = FeedNoteRowData.resolve(
                                for: note,
                                feedService: feedService,
                                nostrService: nostrService
                            )

                            // Optimization: If the parent is the very next note in the feed,
                            // don't show the redundant parent header.
                            let parentIsNext = index + 1 < feedService.filteredNotes.count &&
                                             feedService.filteredNotes[index+1].id == note.parentEventId

                            #if os(iOS)
                            NavigationLink(value: note) {
                                FeedNoteRow(
                                    note: note,
                                    profile: profile,
                                    rowData: rowData,
                                    onReply: {
                                        if note.kind == 6, let refId = note.repostedEventId,
                                           let original = feedService.findNote(id: refId) {
                                            composeContext = ComposeContext(replyTo: original, quoteTo: nil)
                                        } else {
                                            composeContext = ComposeContext(replyTo: note, quoteTo: nil)
                                        }
                                    },
                                    onQuote: {
                                        composeContext = ComposeContext(replyTo: nil, quoteTo: note)
                                    },
                                    onProfile: { pubkey in
                                        showingProfileKey = IdentifiableString(id: pubkey)
                                    },
                                    onMedia: { url in
                                        showingMediaUrl = IdentifiableURL(url: url)
                                    },
                                    showParent: !parentIsNext,
                                    isReplyToNext: parentIsNext
                                )
                                .overlay(alignment: .topTrailing) {
                                    if feedService.feedMode == .popular && feedService.showPopularEngagement,
                                       let score = feedService.popularNoteScores[note.id] {
                                        engagementBadge(rank: index + 1, score: score)
                                            .padding(.top, 8)
                                            .padding(.trailing, 8)
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                            .buttonStyle(.plain)
                            #else
                            FeedNoteRow(
                                note: note,
                                profile: profile,
                                rowData: rowData,
                                onReply: {
                                    if note.kind == 6, let refId = note.repostedEventId,
                                       let original = feedService.notes.first(where: { $0.id == refId }) {
                                        composeContext = ComposeContext(replyTo: original, quoteTo: nil)
                                    } else {
                                        composeContext = ComposeContext(replyTo: note, quoteTo: nil)
                                    }
                                },
                                onQuote: {
                                    composeContext = ComposeContext(replyTo: nil, quoteTo: note)
                                },
                                onProfile: { pubkey in
                                    showingProfileKey = IdentifiableString(id: pubkey)
                                },
                                onMedia: { url in
                                    showingMediaUrl = IdentifiableURL(url: url)
                                },
                                showParent: !parentIsNext,
                                isReplyToNext: parentIsNext
                            )
                            .overlay(alignment: .topTrailing) {
                                if feedService.feedMode == .popular && feedService.showPopularEngagement,
                                   let score = feedService.popularNoteScores[note.id] {
                                    engagementBadge(rank: index + 1, score: score)
                                        .padding(.top, 8)
                                        .padding(.trailing, 8)
                                }
                            }
                            .padding(.horizontal, 16)
                            .onTapGesture {
                                showingNoteId = note.id
                            }
                            #endif
                        }

                        // Infinite scroll sentinel — triggers loadMore when visible
                        if !feedService.filteredNotes.isEmpty {
                            Color.clear
                                .frame(height: 1)
                                .onAppear { feedService.loadMore() }

                            if feedService.isLoadingFeed {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small).tint(Color.havenPurple)
                                    Text(String(localized: "feed.loading.indicator"))
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                }
                                .foregroundColor(.secondary)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity)
                            }
                        }

                    }
                    .environment(\.feedActions, feedActionsValue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    }
                    }
                    .tabBarBottomPadding()
                }
                .refreshable {
                    isRefreshing = true
                    feedService.refresh()
                    // Hold the indicator until loading finishes
                    while feedService.isLoadingFeed {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    isRefreshing = false
                }
                .tint(Color.secondary.opacity(0.6))
                .coordinateSpace(name: "feedScroll")
                .scrollPosition(id: $scrolledNoteID)
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                    isAtTop = value >= -10
                }
                .onChange(of: feedService.isLoadingFeed) { _, isLoading in
                    if !isLoading && feedService.shouldScrollToTopOnLoad {
                        feedService.shouldScrollToTopOnLoad = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                proxy.scrollTo("top", anchor: .top)
                            }
                        }
                    }
                }
                .onChange(of: feedService.pendingNotes.count) { _, count in
                    // Auto-apply pending notes when autoLoad is on, but only
                    // if the user is at the top of the feed to avoid disrupting
                    // their scroll position. Debounced to prevent duplicate calls.
                    if count > 0 && configService.config.autoLoadNewPosts && !feedService.isLoadingFeed && isAtTop {
                        scheduleAutoLoad(delay: 1.5)
                    }
                }
                .onChange(of: isAtTop) { _, atTop in
                    // When the user scrolls back to the top, auto-apply any
                    // accumulated pending notes if auto-load is enabled.
                    if atTop && configService.config.autoLoadNewPosts && !feedService.pendingNotes.isEmpty && !feedService.isLoadingFeed {
                        scheduleAutoLoad(delay: 0.5)
                    }
                }

                // Floating "New Posts" indicator — shown when auto-load is off,
                // or when auto-load is on but the user has scrolled down.
                if !feedService.pendingNotes.isEmpty && (!configService.config.autoLoadNewPosts || !isAtTop) {
                    Button(action: {
                        feedService.applyPendingNotes()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                proxy.scrollTo("top", anchor: .top)
                            }
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                            Text("\(feedService.pendingNotes.count) New Posts")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 20)
                        .background(
                            Capsule()
                                .fill(Color.havenPurple)
                                .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
                        )
                        .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(feedService.pendingNotes.count) new posts, tap to load")
                    .padding(.top, 12)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.8))
                    ))
                    .zIndex(1)
                }

            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FeedTabReselected"))) { _ in
                if !navigationPath.isEmpty {
                    // Inside a note detail — pop back to feed list (keeps scroll position)
                    navigationPath = NavigationPath()
                } else if !isAtTop {
                    // At feed root but scrolled down — scroll to top
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        proxy.scrollTo("top", anchor: .top)
                    }
                } else {
                    // Already at feed root and at top — refresh
                    FeedService.shared.refresh()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ScrollToTop"))) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        proxy.scrollTo("top", anchor: .top)
                    }
                }
            }
            .onChange(of: configService.activeAccountHexPubkey) { _, _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo("top", anchor: .top)
                }
            }
        }
        .overlay {
            if configService.isSwitchingAccount {
                Color.black.opacity(0.15)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: configService.isSwitchingAccount)
        .overlay(alignment: .bottomTrailing) {
            #if os(iOS)
            Button {
                composeContext = ComposeContext(replyTo: nil, quoteTo: nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15, weight: .bold))
                    Text(String(localized: "feed.action.post"))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .foregroundColor(.white)
                .frame(height: 48)
                .padding(.horizontal, 18)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: Color.havenPurple.opacity(0.35), radius: 8, x: 0, y: 4)
                )
            }
            .accessibilityLabel("Compose new post")
            .padding(.trailing, 20)
            .padding(.bottom, 90)
            .hoverEffect(.lift)
            #endif
        }
    }

    private var mediaGridView: some View {
        Group {
            let filteredNotes = feedService.filteredMediaNotes

            if filteredNotes.isEmpty && !feedService.isLoadingFeed {
                VStack(spacing: 20) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 56, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text(String(localized: "feed.media.empty.title"))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                    Text(feedService.mediaFeedMode == .following ? String(localized: "feed.media.empty.following") : String(localized: "feed.media.empty.global"))
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 400)
            } else {
                let columns = [
                    GridItem(.flexible(), spacing: 2),
                    GridItem(.flexible(), spacing: 2),
                    GridItem(.flexible(), spacing: 2)
                ]

                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(filteredNotes) { note in
                        if let firstMediaURL = note.mediaURLs.first {
                            gridCell(for: note, url: firstMediaURL)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    gridMediaSnapshot = filteredNotes
                                    selectedGridMediaNoteId = note.id
                                    isShowingGridMediaViewer = true
                                }
                                .onLongPressGesture(minimumDuration: 0.5) {
                                    showingNoteId = note.id
                                }
                        }
                    }
                }
                .padding(.horizontal, 2)
                
                // Show "Show earlier" button for pagination
                if !filteredNotes.isEmpty {
                    Button {
                        feedService.loadMore()
                    } label: {
                        HStack(spacing: 8) {
                            if feedService.isLoadingFeed {
                                ProgressView().controlSize(.small).tint(Color.havenPurple)
                            } else {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            Text(feedService.isLoadingFeed ? String(localized: "feed.loading.indicator") : String(localized: "feed.media.showEarlier"))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        }
                        .foregroundColor(.secondary)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(Color.platformTertiaryGroupedBackground)
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.platformSeparator, lineWidth: 1))
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                    }
                    .buttonStyle(.plain)
                    .disabled(feedService.isLoadingFeed)
                }
                
                Color.clear.frame(height: 80) // Space for floating button
            }
        }
    }

    private func gridCell(for note: FeedNote, url: URL) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                FeedMediaView(url: url, isThumbnail: true)
                    .frame(width: geo.size.width, height: geo.size.width)
                    .clipped()

                // Indicators overlay
                HStack(spacing: 4) {
                    if note.mediaURLs.count > 1 {
                        Image(systemName: "square.fill.on.square.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Color.black.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else if let extensionType = FeedMediaType.fromExtension(url), extensionType == .video {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Color.black.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(6)
            }
        }
        .aspectRatio(1, contentMode: .fill)
    }
}

// MARK: - FeedNoteRow

struct FeedNoteRow: View {
    let note: FeedNote
    let profile: FeedProfile?
    let rowData: FeedNoteRowData
    var onReply: (() -> Void)? = nil
    var onQuote: (() -> Void)? = nil
    var onProfile: ((String) -> Void)? = nil
    var onMedia: ((URL) -> Void)? = nil
    var showParent: Bool = true
    var isReplyToNext: Bool = false
    var layoutMode: NoteLayoutMode = .sideBySide
    var isFocused: Bool = false
    var suppressCardStyling: Bool = false

    // Zero ObservableObject subscriptions — all data comes via rowData/actions
    @Environment(\.feedActions) private var actions

    @State private var showingEmojiPicker = false
    @State private var showLightning = false
    @State private var zapSheetContext: ZapSheetContext?
    @State private var showingDeleteConfirm = false
    @State private var showingBroadcastSheet = false
    @State private var noLightningAddressAlert = false

    @ViewBuilder
    private var noteBodyContent: some View {
        // Content Body — for empty-content reposts, show the referenced note
        if note.kind == 6 && note.content.isEmpty, note.repostedEventId != nil {
            if let original = rowData.resolvedOriginal {
                let formattedOriginal = NostrContentFormatter.format(original.content, mediaURLs: original.mediaURLs, hideQuotes: true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(formattedOriginal)
                        .font(.system(size: 15, weight: .regular, design: .default))
                        .foregroundColor(Color(red: 1, green: 1, blue: 1))
                        .lineSpacing(2)
                        .lineLimit(nil)
                        .textSelection(.enabled)
                }
                .padding(.top, 4)

                if !original.mediaURLs.isEmpty {
                    feedMediaCarousel(urls: original.mediaURLs)
                        .padding(.top, 4)
                }

                // Link Preview
                if !original.linkURLs.isEmpty {
                    LinkPreviewCard(url: original.linkURLs[0])
                        .padding(.top, 4)
                }
            } else {
                // Still loading the referenced note
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "feed.note.loadingRepost"))
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }
        } else {
            let formattedContent = NostrContentFormatter.format(note.content, mediaURLs: note.mediaURLs, hideQuotes: true)
            VStack(alignment: .leading, spacing: 8) {
                Text(formattedContent)
                    .font(.system(size: 15, weight: .regular, design: .default))
                    .foregroundColor(Color(red: 1, green: 1, blue: 1))
                    .lineSpacing(2)
                    .lineLimit(nil)
                    .textSelection(.enabled)
            }
            .padding(.top, 4)

            // Media previews
            if !note.mediaURLs.isEmpty {
                feedMediaCarousel(urls: note.mediaURLs)
                    .padding(.top, 4)
            }

            // Link Preview
            if !note.linkURLs.isEmpty {
                LinkPreviewCard(url: note.linkURLs[0])
                    .padding(.top, 4)
            }
        }

        // Quoted Notes
        if !note.quotedEventIds.isEmpty {
            VStack(spacing: 8) {
                ForEach(note.quotedEventIds, id: \.self) { quoteId in
                    if let quotedNote = actions.findNote(quoteId) {
                        NavigationLink(value: quotedNote) {
                            QuotedNoteView(note: quotedNote)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear
                            .frame(height: 0)
                            .onAppear {
                                actions.fetchMissingNote(quoteId)
                            }
                    }
                }
            }
            .padding(.top, 4)
        }

        // Actions row - minimal and clean
        HStack(spacing: 12) {
            actionButton(icon: "message", action: { onReply?() })
                .accessibilityLabel("Reply")

            actionButton(
                icon: "arrow.2.squarepath",
                color: rowData.isReposted ? .green : .secondary,
                action: { actions.repostNote(note) }
            )
            .accessibilityLabel(rowData.isReposted ? "Reposted" : "Repost")
            .scaleEffect(rowData.isReposted ? 1.2 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.45), value: rowData.isReposted)

            actionButton(icon: "quote.closing", action: { onQuote?() })
                .accessibilityLabel("Quote")

            actionButton(
                icon: rowData.isLiked ? "heart.fill" : "heart",
                color: rowData.isLiked ? .red : .secondary,
                action: { toggleLike() }
            )
            .accessibilityLabel(rowData.isLiked ? "Unlike" : "Like")
            .scaleEffect(rowData.isLiked ? 1.2 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.45), value: rowData.isLiked)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in
                        #if os(iOS)
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                        #endif
                        showingEmojiPicker = true
                    }
            )
            .popover(isPresented: $showingEmojiPicker) {
                EmojiPickerView { emoji in
                    actions.reactToNote(note, emoji)
                }
                #if os(iOS)
                .presentationDetents([.height(520)])
                #endif
            }

            if rowData.hasNWC {
                let lud16 = actions.getLightningAddress(note.pubkey)
                let isZapped = rowData.zapAmount != nil
                let hasLightning = lud16 != nil
                Image(systemName: isZapped ? "bolt.fill" : "bolt")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isZapped ? .orange : (hasLightning ? .secondary : .secondary.opacity(0.35)))
                    .frame(width: 32, height: 32)
                    .background(isZapped ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
                    .scaleEffect(isZapped ? 1.2 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.45), value: isZapped)
                    .contentShape(Capsule())
                    .accessibilityLabel(isZapped ? "Zapped" : "Zap")
                    .accessibilityHint(hasLightning ? "Tap to send sats" : "No lightning address")
                    .onLongPressGesture {
                        if hasLightning {
                            #if os(iOS)
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            #endif
                            zapSheetContext = ZapSheetContext(defaultAmount: rowData.defaultZapAmount / 1000)
                        }
                    }
                    .onTapGesture {
                        if let lud16 = lud16 {
                            Task { await actions.zapNote(note, lud16, nil) }
                            showLightning = true
                        } else {
                            noLightningAddressAlert = true
                        }
                    }
            }

            ShareLink(
                item: URL(string: "https://mynostrspace.com/thread/\(note.nevent)")!,
                subject: Text(String(localized: "feed.share.subject")),
                message: Text(String(localized: "feed.share.message"))
            ) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
            }

            Button {
                showingBroadcastSheet = true
            } label: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.top, 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Threading View: Parent Note Preview (shows above the current note)
            if showParent, let pId = note.parentEventId {
                if let parent = rowData.parentNote {
                    NavigationLink(value: parent) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(spacing: 0) {
                                    AvatarView(url: rowData.parentProfile?.pictureURL, pubkey: parent.pubkey)
                                        .frame(width: 28, height: 28)
                                        .opacity(1.0)
                                        .onTapGesture {
                                            onProfile?(parent.pubkey)
                                        }

                                    Rectangle()
                                        .fill(Color.havenPurple.opacity(0.3))
                                        .frame(width: 2, height: 14)
                                }
                                .frame(width: 40) // Match main avatar container width

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(rowData.parentProfile?.bestName ?? "Someone")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(Color(red: 0.8, green: 0.8, blue: 0.8))

                                    let parentFormatted = NostrContentFormatter.format(parent.content, mediaURLs: parent.mediaURLs)
                                    if !parentFormatted.characters.isEmpty {
                                        Text(parentFormatted)
                                            .font(.system(size: 13, weight: .regular))
                                            .foregroundColor(Color(red: 0.7, green: 0.7, blue: 0.7))
                                            .lineLimit(2)
                                    }

                                    if !parent.mediaURLs.isEmpty {
                                        FeedMediaView(
                                            url: parent.mediaURLs[0],
                                            maxHeight: 150,
                                            portraitMaxHeight: 200,
                                            isThumbnail: false
                                        )
                                        .frame(maxWidth: .infinity)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .allowsHitTesting(false)
                                    }
                                }
                                .padding(.top, 2)
                                .padding(.bottom, 8)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Skeleton while parent is being fetched
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            Circle()
                                .fill(Color.platformTertiaryGroupedBackground)
                                .frame(width: 28, height: 28)
                            Rectangle()
                                .fill(Color.havenPurple.opacity(0.3))
                                .frame(width: 2, height: 14)
                        }
                        .frame(width: 40)
                        VStack(alignment: .leading, spacing: 5) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.platformTertiaryGroupedBackground)
                                .frame(width: 80, height: 10)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.platformTertiaryGroupedBackground)
                                .frame(width: 140, height: 10)
                        }
                        .padding(.top, 2)
                        .padding(.bottom, 8)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .onAppear {
                        actions.fetchMissingNote(pId)
                    }
                }
            }

            // Repost indicator
            if note.repostedBy != nil {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.2.squarepath")
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(rowData.reposterName ?? shortKey(note.repostedBy!)) reposted")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.green.opacity(0.7))
                .padding(.leading, 52)
            }

            // Main Note Content
            let displayPubkey = rowData.displayPubkey

            if layoutMode == .wide {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        AvatarView(url: rowData.displayProfile?.pictureURL, pubkey: displayPubkey)
                            .frame(width: 40, height: 40)
                            .onTapGesture { onProfile?(displayPubkey) }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(rowData.displayProfile?.bestName ?? shortKey(displayPubkey))
                                    .font(.system(size: 14, weight: .semibold, design: .default))
                                    .foregroundColor(Color(red: 1, green: 1, blue: 1))
                                    .lineLimit(1)

                                if let dp = rowData.displayProfile, let nip05 = dp.nip05, !nip05.isEmpty {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.caption2)
                                        .foregroundColor(Color(red: 0.2, green: 0.8, blue: 0.6))
                                }

                                Spacer()

                                Text(relativeTime(note.createdAt))
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .tracking(0.2)
                            }
                            
                            // Reply indicator - subtle
                            if note.isReply {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrowshape.turn.up.left.fill")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(Color.havenPurple.opacity(0.6))

                                    if let rPubkey = note.replyToPubkey {
                                        let name = rowData.replyToName ?? shortKey(rPubkey)
                                        Text("reply to \(name)")
                                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                                            .foregroundColor(.secondary.opacity(0.7))
                                            .tracking(0.1)
                                            .onAppear {
                                                if rowData.replyToName == nil {
                                                    actions.fetchMissingProfiles([rPubkey])
                                                }
                                            }
                                    }
                                }
                            }
                        }
                    }

                    noteBodyContent
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        if note.parentEventId != nil && rowData.parentNote != nil {
                            Rectangle()
                                .fill(Color.havenPurple.opacity(0.3))
                                .frame(width: 2, height: 10)
                        }

                        AvatarView(url: rowData.displayProfile?.pictureURL, pubkey: displayPubkey)
                            .frame(width: 40, height: 40)
                            .onTapGesture { onProfile?(displayPubkey) }

                        if isReplyToNext {
                            Rectangle()
                                .fill(Color.havenPurple.opacity(0.3))
                                .frame(width: 2)
                                .frame(maxHeight: .infinity)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(rowData.displayProfile?.bestName ?? shortKey(displayPubkey))
                                .font(.system(size: 14, weight: .semibold, design: .default))
                                .foregroundColor(Color(red: 1, green: 1, blue: 1))
                                .lineLimit(1)

                            if let dp = rowData.displayProfile, let nip05 = dp.nip05, !nip05.isEmpty {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.caption2)
                                    .foregroundColor(Color(red: 0.2, green: 0.8, blue: 0.6))
                            }

                            Spacer()

                            Text(relativeTime(note.createdAt))
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundColor(.secondary)
                                .tracking(0.2)
                        }
                        .padding(.top, 4)

                        // Reply indicator - subtle
                        if note.isReply {
                            HStack(spacing: 3) {
                                Image(systemName: "arrowshape.turn.up.left.fill")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(Color.havenPurple.opacity(0.6))

                                if let rPubkey = note.replyToPubkey {
                                    let name = rowData.replyToName ?? shortKey(rPubkey)
                                    Text("reply to \(name)")
                                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                                        .foregroundColor(.secondary.opacity(0.7))
                                        .tracking(0.1)
                                        .onAppear {
                                            if rowData.replyToName == nil {
                                                actions.fetchMissingProfiles([rPubkey])
                                            }
                                        }
                                }
                            }
                        }

                        noteBodyContent
                    }
                }
            }
        } // End of Outer VStack (root row)
        .foregroundColor(Color(red: 1, green: 1, blue: 1))
        .if(!suppressCardStyling) { view in
            view
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
                        .stroke(isFocused ? Color.havenPurple : Color.havenPurple.opacity(note.isReply ? 0.25 : 0.12), lineWidth: isFocused ? 2.0 : (note.isReply ? 1.2 : 0.8))
                )
                .shadow(color: isFocused ? Color.havenPurple.opacity(0.35) : Color.clear, radius: isFocused ? 8 : 0)
                .contentShape(RoundedRectangle(cornerRadius: 12))
                #if os(iOS)
                .hoverEffect(.lift)
                #endif
                .clipped()
        }
        .onAppear {
            // Fetch referenced notes only when this row becomes visible (lazy).
            if note.isReply, let parentId = note.parentEventId, rowData.parentNote == nil {
                actions.fetchMissingNote(parentId)
            }
            if note.kind == 6, note.content.isEmpty,
               let refId = note.repostedEventId, rowData.resolvedOriginal == nil {
                actions.fetchMissingNote(refId)
            }
            for qId in note.quotedEventIds where actions.findNote(qId) == nil {
                actions.fetchMissingNote(qId)
            }
        }
        .overlay {
            LightningAnimationView(isAnimating: $showLightning)
                .allowsHitTesting(false)
        }
        .sheet(item: $zapSheetContext) { context in
            CustomZapSheet(defaultAmount: context.defaultAmount) { amount in
                if let lud16 = actions.getLightningAddress(note.pubkey) {
                    Task { await actions.zapNote(note, lud16, amount) }
                    showLightning = true
                }
            }
            #if os(iOS)
            .presentationDetents([.height(380), .medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color(red: 0.08, green: 0.08, blue: 0.1))
            #endif
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "nostr" {
                let identifier = url.absoluteString.replacingOccurrences(of: "nostr:", with: "")
                if identifier.hasPrefix("npub1") || identifier.hasPrefix("nprofile1") {
                    if let decoded = Bech32.decode(identifier) {
                        onProfile?(decoded.hexString)
                    } else {
                        onProfile?(identifier)
                    }
                    return .handled
                }
                // Future: handle note1/nevent1 navigation here too
            }
            return .systemAction
        })
        .sheet(isPresented: $showingBroadcastSheet) {
            EventBroadcastSheet(note: note)
        }
        .alert("No Lightning Address", isPresented: $noLightningAddressAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This user hasn't configured a lightning address, so they can't receive zaps.")
        }
        .contextMenu {
            if rowData.isOwnNote {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("Delete Post", systemImage: "trash")
                }
            }
        }
        .alert("Delete Post", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) {
                actions.deleteNote(note.id)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Request deletion of this post? Not all relays honor NIP-09 deletion requests.")
        }
    }

    private func actionButton(icon: String, color: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(color)
            .frame(width: 32, height: 32)
            .background(color.opacity(color == .secondary ? 0.1 : 0.15))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        #if os(macOS)
        .onHover { inside in
            // Handle hover state if needed, though .hoverEffect handles it on iOS
        }
        #endif
    }

    // MARK: - Media Grid Helper

    /// Renders media URLs using FeedMediaView in a swipeable carousel.
    @ViewBuilder
    private func feedMediaCarousel(urls: [URL]) -> some View {
        if urls.isEmpty {
            EmptyView()
        } else if urls.count == 1 {
            // Single media — full width, proper aspect ratio
            FeedMediaView(
                url: urls[0],
                onTap: { onMedia?(urls[0]) },
                maxHeight: 400,
                isThumbnail: false
            )
            .frame(maxWidth: .infinity)
        } else {
            // Multiple media — swipeable carousel
            TabView {
                ForEach(urls, id: \.absoluteString) { url in
                    FeedMediaView(
                        url: url,
                        onTap: { onMedia?(url) },
                        maxHeight: 400,
                        isThumbnail: false
                    )
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .mediaTabViewStyleCompat()
            .frame(height: 400)
            // Add a subtle border or background if desired to distinguish bounds
            // But FeedMediaView already has clipShape and overlay
        }
    }

    /// Toggle like: delegates to the appropriate action closure.
    private func toggleLike() {
        if rowData.isLiked {
            actions.unlikeNote(note)
        } else {
            actions.likeNote(note)
        }
    }

    private func shortKey(_ key: String) -> String {
        guard key.count >= 12 else { return key }
        return "npub…" + String(key.suffix(6))
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

// FeedMediaThumbnail has been replaced by FeedMediaView (see Components/FeedMediaView.swift)

// MARK: - AvatarView

private final class AvatarImageCache {
    static let shared = AvatarImageCache()

    private let cache = NSCache<NSURL, PlatformImage>()
    private var inFlight: [URL: [(PlatformImage?) -> Void]] = [:]
    private let lock = NSLock()

    // Downsample target — large enough for a profile header on @3x retina,
    // small enough that 300 entries fit in ~24 MB.
    private static let targetPixelSize: CGFloat = 256
    private static let estimatedCostPerEntry = 256 * 256 * 4 // bytes

    init() {
        cache.countLimit = 300
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    func image(for url: URL) -> PlatformImage? {
        cache.object(forKey: url as NSURL)
    }

    private func store(_ image: PlatformImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL, cost: Self.estimatedCostPerEntry)
    }

    /// Loads an avatar, hitting (in order): memory cache → on-disk cache → network.
    /// Coalesces concurrent requests for the same URL and skips known-404s.
    /// `completion` is always called on the main thread.
    func load(url: URL, completion: @escaping (PlatformImage?) -> Void) {
        if let cached = image(for: url) {
            completion(cached)
            return
        }
        if MediaCacheService.shared.isKnown404(url: url) {
            completion(nil)
            return
        }

        lock.lock()
        if inFlight[url] != nil {
            inFlight[url]?.append(completion)
            lock.unlock()
            return
        }
        inFlight[url] = [completion]
        lock.unlock()

        MediaCacheService.shared.downloadQueue.addOperation { [weak self] in
            guard let self = self else { return }

            // Disk cache
            if let data = MediaCacheService.shared.loadFromCache(url: url),
               let img = Self.downsample(data: data) {
                self.finish(url: url, image: img)
                return
            }

            // Network
            URLSession.shared.dataTask(with: url) { data, response, _ in
                guard let data = data,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let img = Self.downsample(data: data) else {
                    self.finish(url: url, image: nil)
                    return
                }
                MediaCacheService.shared.saveToCache(url: url, data: data)
                self.finish(url: url, image: img)
            }.resume()
        }
    }

    private func finish(url: URL, image: PlatformImage?) {
        if let image = image {
            store(image, for: url)
        }
        lock.lock()
        let callbacks = inFlight.removeValue(forKey: url) ?? []
        lock.unlock()
        DispatchQueue.main.async {
            callbacks.forEach { $0(image) }
        }
    }

    private static func downsample(data: Data) -> PlatformImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetPixelSize
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        #if canImport(AppKit)
        return NSImage(cgImage: cgImage, size: .zero)
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }
}

struct AvatarView: View {
    let url: URL?
    let pubkey: String
    var size: CGFloat = 40
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            Circle()
                .fill(avatarGradient)
                .frame(width: size, height: size)

            if let image = image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Text(String(pubkey.prefix(1)).uppercased())
                    .font(.system(size: max(8, size * 0.325), weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }

            Circle()
                .stroke(Color.platformSeparator, lineWidth: 0.5)
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .onAppear { loadImage() }
        .onChange(of: url) { _, _ in
            image = nil
            loadImage()
        }
        .onChange(of: pubkey) { _, _ in
            image = nil
            loadImage()
        }
    }

    private var avatarGradient: LinearGradient {
        let first = pubkey.unicodeScalars.first?.value ?? 200
        let hue = Double(first % 360) / 360.0
        let saturation = 0.6 + Double((first / 10) % 30) / 100.0

        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: saturation, brightness: 0.75),
                Color(hue: (hue + 0.15).truncatingRemainder(dividingBy: 1), saturation: saturation, brightness: 0.55)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func loadImage() {
        guard let url = url else { return }

        // Fast synchronous path for the memory cache so already-loaded avatars
        // render without a flash.
        if let cached = AvatarImageCache.shared.image(for: url) {
            if image == nil { image = cached }
            return
        }

        guard image == nil else { return }
        AvatarImageCache.shared.load(url: url) { img in
            if let img = img { image = img }
        }
    }
}

// MARK: - Skeleton Loading Row

struct FeedNoteSkeletonRow: View {
    @State private var shimmer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Circle()
                    .fill(Color.platformTertiaryGroupedBackground)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.platformTertiaryGroupedBackground)
                        .frame(width: 100, height: 12)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.platformTertiaryGroupedBackground)
                        .frame(width: 60, height: 10)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.platformTertiaryGroupedBackground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.platformTertiaryGroupedBackground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.platformTertiaryGroupedBackground)
                    .frame(width: 180, height: 12)
            }

            HStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.platformTertiaryGroupedBackground)
                        .frame(width: 28, height: 28)
                }
                Spacer()
            }
        }
        .padding(14)
        .background(Color.platformSecondaryGroupedBackground)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.platformSeparator, lineWidth: 0.8))
        .opacity(shimmer ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: shimmer)
        .onAppear { shimmer = true }
    }
}

