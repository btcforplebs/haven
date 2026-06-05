import SwiftUI
import UIKit

// MARK: - iOS ContentView

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @StateObject private var nostrService = NostrService.shared
    @StateObject private var statsService = StatsService.shared
    @StateObject private var feedService = FeedService.shared

    @State private var selectedTab = 0
    @State private var showingDMInbox = false
    @State private var pendingMentionNoteId: IdentifiableString?

    init() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }

    var body: some View {
        Group {
            if !configService.config.hasCompletedSetup {
                SetupWizardView {
                    relayManager.startRelay(config: configService.config)
                }
            } else {
                if horizontalSizeClass == .regular {
                    iPadSidebarView(selectedTab: $selectedTab)
                } else {
                    iPhoneTabView(selectedTab: $selectedTab)
                }
            }
        }
        .onAppear {
            DMService.shared.startListening()
            // Auto-connect NIP-46 remote signer if configured
            if configService.config.hasCompletedSetup && configService.config.activeSigningMode() == "nip46" {
                NIP46Service.shared.connectFromConfig()
            }
            // Replay any queued notification action from a cold start
            if let action = AppDelegate.pendingAction {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    AppDelegate.dispatchAction(action)
                }
            }
        }
        .onChange(of: relayManager.isRunning) { _, running in
            if running, let action = AppDelegate.pendingAction {
                AppDelegate.dispatchAction(action)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenViewer)) { _ in
            selectedTab = 4 // Relay tab
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenFeed)) { _ in
            selectedTab = 0 // Feed tab
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenDMInbox)) { _ in
            selectedTab = 2 // Profile tab
            showingDMInbox = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenMentions)) { notification in
            selectedTab = 0 // Feed tab
            if let eventId = notification.object as? String {
                pendingMentionNoteId = IdentifiableString(id: eventId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenWallet)) { _ in
            selectedTab = 2 // Profile tab
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayLikes)) { _ in
            selectedTab = 4 // Relay tab
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayNotes)) { _ in
            selectedTab = 4 // Relay tab
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayZaps)) { _ in
            selectedTab = 4 // Relay tab
        }
        .sheet(isPresented: $showingDMInbox) {
            NavigationStack {
                DMInboxView()
                    .environmentObject(NostrService.shared)
                    .environmentObject(ConfigService.shared)
            }
        }
        .sheet(item: $pendingMentionNoteId) { noteId in
            NoteDetailViewWrapper(noteId: noteId.id, onDismiss: { pendingMentionNoteId = nil })
                .environmentObject(NostrService.shared)
                .environmentObject(ConfigService.shared)
        }
    }
}

// MARK: - iPad Sidebar View

struct iPadSidebarView: View {
    @Binding var selectedTab: Int
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @StateObject private var nostrService = NostrService.shared
    @StateObject private var feedService = FeedService.shared
    @StateObject private var dmService = DMService.shared
    @State private var showingAccountSwitcher = false
    @State private var searchPath = NavigationPath()
    @State private var profilePath = NavigationPath()
    @State private var mediaPath = NavigationPath()
    @State private var relayPath = NavigationPath()

    private var activeHex: String { configService.activeAccountHexPubkey }

    private var isOwner: Bool {
        configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasMultipleAccounts: Bool {
        configService.allAccountNpubs.count > 1
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { selectedTab },
                set: { if let val = $0 { selectedTab = val } }
            )) {
                // Account switcher section
                Section {
                    Button {
                        if hasMultipleAccounts {
                            showingAccountSwitcher.toggle()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(
                                url: nostrService.profiles[activeHex]?.pictureURL,
                                pubkey: activeHex
                            )
                            .id(activeHex)
                            .frame(width: 32, height: 32)
                            .overlay(
                                Circle()
                                    .stroke(
                                        isOwner ? Color.havenPurple.opacity(0.4) : Color.orange.opacity(0.8),
                                        lineWidth: isOwner ? 1.5 : 2
                                    )
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(nostrService.profiles[activeHex]?.bestName ?? (isOwner ? "Owner" : "User"))
                                    .font(.appSystem(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                Text(isOwner ? "Owner Key" : "Whitelisted")
                                    .font(.appSystem(size: 10))
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if hasMultipleAccounts {
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.appSystem(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                // Navigation tabs
                Section {
                    NavigationLink(value: 0) {
                        Label("Feed", systemImage: "person.2.wave.2")
                    }
                    NavigationLink(value: 1) {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    NavigationLink(value: 2) {
                        HStack {
                            Label("Profile", systemImage: "person.crop.circle")
                            Spacer()
                            if dmService.totalUnreadCount > 0 {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 8, height: 8)
                            }
                        }
                    }
                    NavigationLink(value: 3) {
                        Label("Media", systemImage: "photo.on.rectangle")
                    }
                    NavigationLink(value: 4) {
                        HStack {
                            Label("Relay", systemImage: "doc.text.image")
                            Spacer()
                            if relayManager.hasNewRelayActivity {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 8, height: 8)
                            }
                        }
                    }
                    NavigationLink(value: 5) {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("Nostr Vault")
        } detail: {
            switch selectedTab {
            case 0:
                FeedView()
            case 1:
                NavigationStack(path: $searchPath) {
                    SearchView()
                        .navigationTitle("Search")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(.hidden, for: .navigationBar)
                        .navigationDestination(for: FeedNote.self) { note in
                            NoteDetailView(note: note)
                        }
                }
            case 2:
                NavigationStack(path: $profilePath) {
                    ProfileView(pubkey: activeHex, embeddedInNavigation: false)
                        .navigationTitle("Profile")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(.hidden, for: .navigationBar)
                        .navigationDestination(for: FeedNote.self) { note in
                            NoteDetailView(note: note)
                        }
                }
                .id(activeHex)
            case 3:
                NavigationStack(path: $mediaPath) {
                    MediaTabView()
                        .navigationTitle("")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(.hidden, for: .navigationBar)
                        .navigationDestination(for: FeedNote.self) { note in
                            NoteDetailView(note: note)
                        }
                }
            case 4:
                NavigationStack(path: $relayPath) {
                    ViewerView()
                        .navigationTitle("")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(.hidden, for: .navigationBar)
                        .navigationDestination(for: FeedNote.self) { note in
                            NoteDetailView(note: note)
                        }
                }
            case 5:
                NavigationStack {
                    SettingsView(isEmbedded: true)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(.hidden, for: .navigationBar)
                }
            default:
                FeedView()
            }
        }
        .onAppear {
            if configService.config.hasCompletedSetup && relayManager.state == .idle {
                relayManager.startRelay(config: configService.config)
            }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == 0 { feedService.markViewed() }
            if tab == 4 { relayManager.markRelayViewed() }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                PostActionNotificationBanner()
                ZapNotificationBanner()
                FollowNotificationBanner()
                MediaUploadNotificationBanner()
                ActionToastBanner()
                ErrorNotificationBanner()
            }
            .padding(.top, 4)
            .allowsHitTesting(true)
        }
        .sheet(isPresented: $showingAccountSwitcher) {
            AccountSwitcherView(configService: configService)
        }
    }
}

// MARK: - iPhone Tab View

struct iPhoneTabView: View {
    @Binding var selectedTab: Int
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @StateObject private var nostrService = NostrService.shared
    @StateObject private var feedService = FeedService.shared
    @StateObject private var dmService = DMService.shared

    @State private var searchPath = NavigationPath()
    @State private var profilePath = NavigationPath()
    @State private var mediaPath = NavigationPath()
    @State private var relayPath = NavigationPath()

    private var activeHex: String { configService.activeAccountHexPubkey }

    var body: some View {
        TabView(selection: $selectedTab) {
            FeedView()
                .toolbar(.hidden, for: .tabBar)
                .tag(0)

            NavigationStack(path: $searchPath) {
                SearchView()
                    .navigationTitle("Search")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .navigationDestination(for: FeedNote.self) { note in
                        NoteDetailView(note: note)
                    }
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(1)

            NavigationStack(path: $profilePath) {
                ProfileView(pubkey: activeHex, embeddedInNavigation: false)
                    .navigationTitle("Profile")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .navigationDestination(for: FeedNote.self) { note in
                        NoteDetailView(note: note)
                    }
            }
            .id(activeHex)
            .toolbar(.hidden, for: .tabBar)
            .tag(2)

            NavigationStack(path: $mediaPath) {
                MediaTabView()
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .navigationDestination(for: FeedNote.self) { note in
                        NoteDetailView(note: note)
                    }
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(3)

            NavigationStack(path: $relayPath) {
                ViewerView()
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .navigationDestination(for: FeedNote.self) { note in
                        NoteDetailView(note: note)
                    }
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(4)
        }
        .tint(.havenPurple)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomTabBar(
                selectedTab: $selectedTab,
                searchPath: $searchPath,
                profilePath: $profilePath,
                mediaPath: $mediaPath,
                relayPath: $relayPath,
                configService: configService,
                relayManager: relayManager,
                nostrService: nostrService,
                dmService: dmService,
                feedService: feedService
            )
        }
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                PostActionNotificationBanner()
                ZapNotificationBanner()
                FollowNotificationBanner()
                MediaUploadNotificationBanner()
                ActionToastBanner()
                ErrorNotificationBanner()
            }
            .padding(.top, 4)
            .allowsHitTesting(true)
        }
        .onAppear {
            if configService.config.hasCompletedSetup && relayManager.state == .idle {
                relayManager.startRelay(config: configService.config)
            }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == 0 { feedService.markViewed() }
            if tab == 4 { relayManager.markRelayViewed() }
        }
    }
}

// MARK: - Dedicated Bottom Tab Bar

struct BottomTabBar: View {
    @Binding var selectedTab: Int
    @Binding var searchPath: NavigationPath
    @Binding var profilePath: NavigationPath
    @Binding var mediaPath: NavigationPath
    @Binding var relayPath: NavigationPath

    @ObservedObject var configService: ConfigService
    @ObservedObject var relayManager: RelayProcessManager
    @ObservedObject var nostrService: NostrService
    @ObservedObject var dmService: DMService
    @ObservedObject var feedService: FeedService

    @State private var isCollapsed: Bool = false

    private var activeHex: String { configService.activeAccountHexPubkey }

    private var relayStatusColor: Color {
        if relayManager.isBooting {
            return .yellow
        } else if relayManager.isRunning && relayManager.isWotSyncing {
            return .orange
        } else if relayManager.isRunning {
            return .green
        } else {
            return .red
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if isCollapsed {
                collapsedContent
            } else {
                expandedContent
            }
        }
        .padding(.vertical, isCollapsed ? 6 : 10)
        .padding(.horizontal, isCollapsed ? 6 : 8)
        .applyGlassCapsule()
        .padding(.horizontal, isCollapsed ? 0 : 16)
        .padding(.bottom, 0)
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: isCollapsed)
        .onChange(of: feedService.feedScrollingDown) { _, scrollingDown in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                isCollapsed = scrollingDown
            }
        }
        .onChange(of: selectedTab) { _, _ in
            // Reset scroll state when switching tabs so bar starts expanded
            feedService.feedScrollingDown = false
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                isCollapsed = false
            }
        }
    }

    // MARK: - Expanded Content

    @ViewBuilder
    private var expandedContent: some View {
        tabItem(index: 0, title: "Feed", icon: "person.2.wave.2") {
            NotificationCenter.default.post(name: NSNotification.Name("FeedTabReselected"), object: nil)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.85)))

        tabItem(index: 1, title: "Search", icon: "magnifyingglass") {
            if !searchPath.isEmpty {
                searchPath = NavigationPath()
            } else {
                NotificationCenter.default.post(name: NSNotification.Name("SearchScrollToTop"), object: nil)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.85)))

        expandedProfileTabItem
            .transition(.opacity.combined(with: .scale(scale: 0.85)))

        tabItem(index: 3, title: "Media", icon: "photo.on.rectangle") {
            if !mediaPath.isEmpty {
                mediaPath = NavigationPath()
            } else {
                NotificationCenter.default.post(name: NSNotification.Name("MediaScrollToTop"), object: nil)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.85)))

        tabItem(index: 4, title: "Relay", icon: "doc.text.image", hasRedBadge: relayManager.hasNewRelayActivity) {
            if !relayPath.isEmpty {
                relayPath = NavigationPath()
            } else {
                relayManager.markRelayViewed()
                NotificationCenter.default.post(name: NSNotification.Name("RelayScrollToTop"), object: nil)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }

    // MARK: - Collapsed Content

    private var collapsedFABIcon: String {
        selectedTab <= 2 ? "square.and.pencil" : "antenna.radiowaves.left.and.right"
    }

    private var collapsedFABColor: Color {
        selectedTab <= 2 ? Color.havenPurple : relayStatusColor
    }

    @ViewBuilder
    private var collapsedContent: some View {
        HStack(spacing: 16) {
            // Profile avatar — tap to expand tab bar
            Button {
                feedService.feedScrollingDown = false
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    isCollapsed = false
                }
            } label: {
                AvatarView(url: nostrService.profiles[activeHex]?.pictureURL, pubkey: activeHex, size: 36)
                    .overlay(
                        Circle()
                            .stroke(Color.havenPurple.opacity(0.6), lineWidth: 2)
                    )
                    .overlay(alignment: .topTrailing) {
                        if dmService.totalUnreadCount > 0 || relayManager.hasNewRelayActivity {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 10, height: 10)
                                .offset(x: 2, y: -2)
                        }
                    }
            }
            .buttonStyle(.plain)
            .contextMenu {
                if configService.allAccountNpubs.count > 1 {
                    ForEach(configService.allAccountNpubs, id: \.self) { npub in
                        let isOwner = npub == configService.config.ownerNpub
                        let currentNpub = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
                        let isCurrent = currentNpub.isEmpty ? isOwner : npub == currentNpub
                        let hex = Bech32.decode(npub)?.hexString ?? ""
                        let name = nostrService.profiles[hex]?.bestName ?? (isOwner ? "Owner" : String(npub.prefix(8)))

                        Button {
                            configService.switchActiveAccount(to: npub)
                        } label: {
                            if isCurrent {
                                Label(name, systemImage: "checkmark")
                            } else {
                                Text(name)
                            }
                        }
                    }
                } else {
                    Text("No other accounts")
                }
            }

            // Contextual FAB icon — triggers compose or relay dashboard
            Button {
                if selectedTab <= 2 {
                    NotificationCenter.default.post(name: .composeFromTabBar, object: selectedTab)
                } else {
                    NotificationCenter.default.post(name: .openRelayDashboard, object: selectedTab)
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(collapsedFABColor.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: collapsedFABIcon)
                        .font(.appSystem(size: 15, weight: .bold))
                        .foregroundColor(collapsedFABColor)
                }
            }
            .buttonStyle(.plain)
        }
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    // MARK: - Tab Item

    private func tabItem(index: Int, title: String, icon: String, hasRedBadge: Bool = false, onReselect: @escaping () -> Void) -> some View {
        let selected = selectedTab == index
        return Button {
            if selectedTab == index {
                onReselect()
            } else {
                selectedTab = index
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.appSystem(size: 20, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.havenPurple : .white.opacity(0.5))
                    .frame(height: 24)
                    .overlay(alignment: .topTrailing) {
                        if hasRedBadge {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                                .offset(x: 4, y: -2)
                        }
                    }
                Text(title)
                    .font(.appSystem(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.havenPurple : .white.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded Profile Tab Item

    private var expandedProfileTabItem: some View {
        let selected = selectedTab == 2
        return Button {
            if selectedTab == 2 {
                if !profilePath.isEmpty {
                    profilePath = NavigationPath()
                } else {
                    NotificationCenter.default.post(name: NSNotification.Name("ProfileScrollToTop"), object: nil)
                }
            } else {
                selectedTab = 2
            }
        } label: {
            VStack(spacing: 4) {
                AvatarView(url: nostrService.profiles[activeHex]?.pictureURL, pubkey: activeHex, size: 24)
                    .overlay(
                        Circle()
                            .stroke(selected ? Color.havenPurple : .white.opacity(0.3), lineWidth: selected ? 2 : 1)
                    )
                    .frame(height: 24)
                    .overlay(alignment: .topTrailing) {
                        if dmService.totalUnreadCount > 0 {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                                .offset(x: 4, y: -2)
                        }
                    }
                Text("Profile")
                    .font(.appSystem(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.havenPurple : .white.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(activeHex)
        .contextMenu {
            if configService.allAccountNpubs.count > 1 {
                ForEach(configService.allAccountNpubs, id: \.self) { npub in
                    let isOwner = npub == configService.config.ownerNpub
                    let currentNpub = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
                    let isCurrent = currentNpub.isEmpty ? isOwner : npub == currentNpub
                    let hex = Bech32.decode(npub)?.hexString ?? ""
                    let name = nostrService.profiles[hex]?.bestName ?? (isOwner ? "Owner" : String(npub.prefix(8)))

                    Button {
                        configService.switchActiveAccount(to: npub)
                    } label: {
                        if isCurrent {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            } else {
                Text("No other accounts")
            }
        }
    }
}

// MARK: - AppState for iOS

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()
    @Published var isOnboarded = false
    @Published var selectedTab = 0
    private init() {}
}
