import Foundation
import Combine

/// Recipes feed.
///
/// Recipes are ordinary NIP-23 long-form events (kind 30023) tagged
/// `zapcooking` or `nostrcooking`. Unlike Articles they are written by
/// strangers, so they fall outside the `authors: follows` set the device's own
/// relay syncs — this feed therefore talks to external relays directly and
/// keeps its results in memory only. Nothing is written to the owner's relay.
@MainActor
final class RecipeFeedService: ObservableObject {
    static let shared = RecipeFeedService()

    /// Recipes newest-first, one per `pubkey:d` address.
    @Published private(set) var recipes: [FeedNote] = []
    @Published private(set) var isLoading = false
    /// Set when every relay failed or returned nothing.
    @Published private(set) var loadFailed = false
    /// Selected category chip, or nil for "All".
    @Published var selectedCategory: String?

    /// The `t` tags that mark an event as a recipe.
    static let recipeTopics = ["zapcooking", "nostrcooking"]
    /// Prefix zap.cooking uses for its category tags, e.g. `zapcooking-dessert`.
    private static let categoryPrefix = "zapcooking-"

    private var clients: [WebSocketClient] = []
    private var cancellables = Set<AnyCancellable>()
    private var collected: [String: FeedNote] = [:]
    private var loadTimeout: Timer?
    private var lastLoadedAt: Date?

    /// Results older than this are refetched when the feed is opened again.
    private static let staleAfter: TimeInterval = 10 * 60

    private init() {}

    /// The most common categories in the current results.
    ///
    /// Capped deliberately: a 200-recipe page carries close to 300 distinct
    /// `zapcooking-*` tags (measured against nos.lol, 2026-09-05), most of them
    /// used once. Showing all of them would be a chip bar nobody can scroll.
    /// Ranked by frequency, then alphabetically so equal counts are stable.
    var categories: [String] {
        var counts: [String: Int] = [:]
        for recipe in recipes {
            // A recipe tagged `zapcooking-beef` twice must not count twice.
            var seenInRecipe = Set<String>()
            for topic in recipe.longFormMetadata.topics where topic.hasPrefix(Self.categoryPrefix) {
                let name = String(topic.dropFirst(Self.categoryPrefix.count))
                guard !name.isEmpty, seenInRecipe.insert(name).inserted else { continue }
                counts[name, default: 0] += 1
            }
        }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(Self.maxCategories)
            .map(\.key)
    }

    /// How many category chips the bar shows.
    private static let maxCategories = 12

    /// Every category present in the current results, uncapped.
    private var allCategories: Set<String> {
        var names = Set<String>()
        for recipe in recipes {
            for topic in recipe.longFormMetadata.topics where topic.hasPrefix(Self.categoryPrefix) {
                let name = String(topic.dropFirst(Self.categoryPrefix.count))
                if !name.isEmpty { names.insert(name) }
            }
        }
        return names
    }

    /// Recipes after the category chip is applied.
    var visibleRecipes: [FeedNote] {
        guard let category = selectedCategory else { return recipes }
        let tag = Self.categoryPrefix + category
        return recipes.filter { $0.longFormMetadata.topics.contains(tag) }
    }

    /// Loads on first open, and again once the results have gone stale.
    /// Cheap to call from `onAppear`.
    func loadIfNeeded() {
        if isLoading { return }
        if let lastLoadedAt, Date().timeIntervalSince(lastLoadedAt) < Self.staleAfter, !recipes.isEmpty { return }
        refresh()
    }

    func refresh() {
        disconnect()
        collected.removeAll()
        loadFailed = false
        isLoading = true

        let relayURLs = Self.relayURLs
        guard !relayURLs.isEmpty else {
            isLoading = false
            loadFailed = true
            return
        }

        let filter: [String: Any] = [
            "kinds": [30023],
            "#t": Self.recipeTopics,
            "limit": 200
        ]
        let subId = "recipes-\(UUID().uuidString.prefix(8))"
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys

        for url in relayURLs {
            let client = WebSocketClient()
            client.isTemporary = true
            clients.append(client)

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] message in
                    self?.handle(message: message, blocked: blocked)
                }
                .store(in: &cancellables)

            client.connect(url: url)

            // The socket is not open the instant connect() returns; the rest of
            // the feed pipeline uses the same short delay before its REQ.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let req = ["REQ", subId, filter] as [Any]
                if let data = try? JSONSerialization.data(withJSONObject: req),
                   let text = String(data: data, encoding: .utf8) {
                    client.send(text: text)
                }
            }
        }

        // Stop waiting on relays that never answer, and keep whatever arrived.
        loadTimeout?.invalidate()
        loadTimeout = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finishLoading() }
        }
    }

    func disconnect() {
        loadTimeout?.invalidate()
        loadTimeout = nil
        cancellables.removeAll()
        clients.forEach { $0.disconnect() }
        clients.removeAll()
    }

    // MARK: - Private

    /// Relays to ask. Recipe authors are strangers, so the owner's own relay
    /// has nothing to contribute here and is deliberately not queried.
    private static var relayURLs: [URL] {
        let configured = ConfigService.shared.config.activeFeedRelays
        let strings = configured.isEmpty ? ["wss://relay.primal.net", "wss://nos.lol"] : configured
        return strings.compactMap { URL(string: $0) }
    }

    private func handle(message: String, blocked: Set<String>) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json.first as? String else { return }

        if type == "EOSE" {
            publish()
            // One relay reaching EOSE is enough to show results; the others
            // keep streaming into `collected` and republish as they land.
            return
        }

        guard type == "EVENT", json.count >= 3,
              let event = json[2] as? [String: Any],
              let id = event["id"] as? String,
              let pubkey = event["pubkey"] as? String,
              let content = event["content"] as? String,
              let createdAt = event["created_at"] as? Int64,
              let kind = event["kind"] as? Int,
              let tags = event["tags"] as? [[String]],
              kind == 30023,
              !blocked.contains(pubkey),
              collected[id] == nil
        else { return }

        collected[id] = FeedNote(
            id: id,
            pubkey: pubkey,
            content: content,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            tags: tags,
            kind: kind
        )
        publish()
    }

    private func publish() {
        recipes = FeedFilterEngine.dedupeAddressable(Array(collected.values))
        if !recipes.isEmpty {
            isLoading = false
            loadFailed = false
            lastLoadedAt = Date()
        }
        // A category can disappear entirely when results change underneath the
        // chip. Validate against every category present, not the capped chip
        // list — otherwise a selection silently resets the moment more results
        // push it past position 12.
        if let selectedCategory, !allCategories.contains(selectedCategory) {
            self.selectedCategory = nil
        }
    }

    private func finishLoading() {
        isLoading = false
        loadFailed = recipes.isEmpty
        if !recipes.isEmpty { lastLoadedAt = Date() }
        disconnect()
    }
}
