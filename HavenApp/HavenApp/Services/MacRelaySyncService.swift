import Foundation
import Combine

/// Service that syncs missed notes from a remote Mac Haven relay.
///
/// The Mac version of Haven runs 24/7 and accumulates all notes. When the iOS
/// version resumes, this service connects to the Mac relay, requests events
/// since the last sync timestamp, and feeds them into the local relay so
/// the Viewer and Feed have complete data.
@MainActor
class MacRelaySyncService: ObservableObject {
    static let shared = MacRelaySyncService()

    // MARK: - Published State
    @Published var isSyncing = false
    @Published var syncStatus: String = ""
    @Published var lastSyncDate: Date?
    @Published var notesSynced: Int = 0
    
    // MARK: - Private
    private var client: WebSocketClient?
    private var cancellables = Set<AnyCancellable>()
    private let processingQueue = DispatchQueue(label: "com.haven.mac-relay-sync", qos: .userInitiated)

    // BadgerDB (Haven's default) enforces MaxLimit=1000. The query engine honours
    // filter.Limit only when 0 < filter.Limit <= MaxLimit; values above MaxLimit
    // silently fall back to MaxLimit/4 = 250.  Requesting exactly 1000 therefore
    // maximises events per page on BadgerDB, and still fits within LMDB's 1500 cap.
    private let pageLimit = 1000

    // Minimum spacing between opportunistic (syncIfConfigured) rounds — does not
    // apply to forceSync(), which is an explicit user action. See syncIfConfigured().
    private var lastAutoSyncAt: Date = .distantPast
    private let minAutoSyncGap: TimeInterval = 60

    /// Thread-safe accumulator for background event processing.
    /// All access is serialized on `processingQueue` to avoid data races.
    private let bgAccumulator = SyncAccumulator()

    final class SyncAccumulator: @unchecked Sendable {
        var pageEventCount: Int = 0
        var pageOldestTimestamp: Int64 = Int64.max
        var syncedEventIds = Set<String>()
        var pendingEvents: [String: [[String: Any]]] = [
            "outbox": [],
            "inbox": [],
            "private": [],
            "chat": []
        ]

        func reset() {
            pageEventCount = 0
            pageOldestTimestamp = Int64.max
            syncedEventIds.removeAll()
            pendingEvents = ["outbox": [], "inbox": [], "private": [], "chat": []]
        }

        func resetPage() {
            pageEventCount = 0
            pageOldestTimestamp = Int64.max
        }
    }
    
    /// UserDefaults key for the last successful sync timestamp
    private let lastSyncKey = "com.haven.macRelay.lastSyncTimestamp"

    /// The timestamp of the last successful sync (persisted across app launches)
    var lastSyncTimestamp: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: lastSyncKey)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: lastSyncKey) }
    }

    // MARK: - Logging

    /// Mirrors to the console in DEBUG and always appends to the in-app Logs
    /// viewer (RelayProcessManager.logStore) — this service runs from
    /// background-task contexts where nobody is tethered to Xcode to see a
    /// plain print(), so without this every skip/failure was invisible.
    private func log(_ message: String, level: String = "INFO") {
        #if DEBUG
        print("MacRelaySyncService: \(message)")
        #endif
        RelayProcessManager.shared.logStore.append(
            RelayProcessManager.LogEntry(timestamp: Date(), level: level, message: "MacRelaySyncService: \(message)")
        )
    }

    // MARK: - Public API

    /// Syncs missed notes from the configured Mac relay.
    /// Call this on app foreground or after the local relay finishes booting.
    func syncIfConfigured() {
        let macURL = ConfigService.shared.config.macRelayURL
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !macURL.isEmpty else {
            log("skip: no Mac relay URL configured")
            return
        }
        guard !isSyncing else {
            log("skip: already syncing")
            return
        }

        // syncIfConfigured() is triggered opportunistically from several call sites
        // (FeedService on every feed EOSE, scene foreground, background tasks). If
        // feed relays cycle/reconnect repeatedly, those can fire back-to-back with no
        // overlap for isSyncing to catch — each round dials fresh connections to both
        // the Mac relay and the local relay, and enough of them in a row can starve
        // the local embedded relay's own connections (observed: NostrService giving
        // up on wss://127.0.0.1 entirely). Same fix as feedsync.go's minSyncGap.
        let sinceLastAutoSync = Date().timeIntervalSince(lastAutoSyncAt)
        guard sinceLastAutoSync >= minAutoSyncGap else {
            log("skip: auto-synced \(Int(sinceLastAutoSync))s ago, within \(Int(minAutoSyncGap))s gap")
            return
        }

        // Ensure local relay is ready before syncing
        guard RelayProcessManager.shared.isRunning,
              !RelayProcessManager.shared.isBooting else {
            log("skip: local relay not ready (running=\(RelayProcessManager.shared.isRunning), booting=\(RelayProcessManager.shared.isBooting))", level: "WARN")
            return
        }

        lastAutoSyncAt = Date()
        performSync(macRelayURL: macURL)
    }
    /// Force a manual sync (e.g., from a button tap in settings)
    func forceSync() {
        let macURL = ConfigService.shared.config.macRelayURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !macURL.isEmpty else {
            syncStatus = "No Mac relay URL configured"
            return
        }
        
        // Cancel any existing sync
        cancelSync()
        
        // For a force sync, we go back 24 hours from the current last sync 
        // to catch anything that might have been missed during clock drifts or filter issues.
        let startTime = max(0, lastSyncTimestamp - (24 * 3600))
        performSync(macRelayURL: macURL, fromTimestamp: startTime)
    }
    
    /// Resets the sync timestamp to zero, forcing the next sync to start from the beginning.
    func resetSync() {
        lastSyncTimestamp = 0
        lastSyncDate = nil
        syncStatus = "Sync timestamp reset"
    }
    
    func cancelSync() {
        client?.disconnect()
        client = nil
        cancellables.removeAll()
        isSyncing = false
    }

    
    // MARK: - Sync Logic
    
    private func performSync(macRelayURL: String, fromTimestamp: Int64? = nil) {
        // Normalize the URL — convert any scheme (including https://) to wss://
        var url = macRelayURL
        if url.hasPrefix("https://") {
            url = "wss://" + url.dropFirst("https://".count)
        } else if url.hasPrefix("http://") {
            url = "ws://" + url.dropFirst("http://".count)
        } else if !url.hasPrefix("wss://") && !url.hasPrefix("ws://") {
            url = "wss://" + url
        }

        // Connect to all relay endpoints to get complete sync
        let endpoints = [url, url + "/inbox", url + "/private", url + "/chat"]
        
        isSyncing = true
        notesSynced = 0
        bgAccumulator.reset()
        syncStatus = "Connecting to Mac relay..."
        
        // Use provided timestamp or 1-hour overlap from last known sync
        let startTime = fromTimestamp ?? max(0, lastSyncTimestamp - 3600)

        log("starting sync from \(endpoints) since timestamp \(startTime) (original last sync: \(lastSyncTimestamp))")

        syncFromEndpoints(endpoints, index: 0, since: startTime)
    }
    
    /// Iterates through each relay endpoint sequentially, paginating within each endpoint
    /// using `until` as a cursor until fewer than `pageLimit` events are returned.
    private func syncFromEndpoints(_ endpoints: [String], index: Int, since: Int64, until: Int64? = nil) {
        guard index < endpoints.count else {
            finishSync()
            return
        }

        let endpoint = endpoints[index]
        guard let url = URL(string: endpoint) else {
            syncFromEndpoints(endpoints, index: index + 1, since: since)
            return
        }

        // Reset page-level tracking for this request (on processingQueue for thread safety)
        processingQueue.sync { bgAccumulator.resetPage() }

        let wsClient = WebSocketClient()
        wsClient.isTemporary = true
        self.client = wsClient

        let subId = "mac-sync-\(UUID().uuidString.prefix(6))"

        // /private and /chat require NIP-42 AUTH before they'll answer a REQ (see
        // haven-go/init.go's khatru.RequestAuth + policies.MustAuth for those two
        // sub-relays). Without this, our REQ is silently rejected (a CLOSED we don't
        // otherwise act on) and the page just sits until the 60s safety timeout below
        // fires — which is exactly why private/chat catch-up was never actually
        // completing. authSent guards against re-authing on every message.
        var authSent = false

        wsClient.messageSubject
            .receive(on: processingQueue)
            .sink { [weak self] message in
                guard let self = self else { return }
                if !authSent,
                   let data = message.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                   json.first as? String == "AUTH",
                   let challenge = json[safe: 1] as? String {
                    authSent = true
                    self.log("received AUTH challenge from \(endpoint), authenticating")
                    self.sendAuthResponse(challenge: challenge, to: wsClient, endpoint: endpoint)
                    // The original REQ (sent immediately on connect, before this challenge
                    // arrived) was rejected pre-auth — resend now that we've authenticated.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.sendSyncRequest(to: wsClient, subId: subId, url: url, since: since, until: until)
                    }
                    return
                }
                self.processMessage(message, subId: subId, endpoints: endpoints, index: index, since: since)
            }
            .store(in: &cancellables)

        wsClient.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .connected:
                    let pageDesc = until != nil ? " (page, until \(until!))" : ""
                    self.syncStatus = "Fetching from \(url.host ?? "Mac relay")\(pageDesc)..."
                    self.sendSyncRequest(to: wsClient, subId: subId, url: url, since: since, until: until)
                case .error:
                    self.log("connection error to \(endpoint)", level: "WARN")
                    // On error, skip to next endpoint
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.syncFromEndpoints(endpoints, index: index + 1, since: since)
                    }
                default:
                    break
                }
            }
            .store(in: &cancellables)

        wsClient.connect(url: url)

        // Safety timeout per page — 60 seconds is generous for 500 events
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self = self, self.isSyncing else { return }
            if self.client === wsClient && wsClient.connectionState != .disconnected {
                self.log("timeout for \(endpoint) until=\(until ?? -1), advancing", level: "WARN")
                wsClient.disconnect()
                self.syncFromEndpoints(endpoints, index: index + 1, since: since)
            }
        }
    }

    private func sendSyncRequest(to client: WebSocketClient, subId: String, url: URL, since: Int64, until: Int64? = nil) {
        let npub = ConfigService.shared.config.ownerNpub
        let ownerHex = Bech32.decode(npub)?.hexString ?? ""

        // Page-size request. Haven (khatru) caps at 500; requesting exactly pageLimit lets us
        // detect when we've hit the cap and need to paginate.
        var filter1: [String: Any] = ["limit": pageLimit]
        if since > 0 { filter1["since"] = since }
        if let u = until { filter1["until"] = u }

        var filters: [Any] = [filter1]

        if !ownerHex.isEmpty {
            var filter2: [String: Any] = ["#p": [ownerHex], "limit": pageLimit]
            if since > 0 { filter2["since"] = since }
            if let u = until { filter2["until"] = u }
            filters.append(filter2)
        }

        let req: [Any] = ["REQ", subId] + filters

        if let data = try? JSONSerialization.data(withJSONObject: req),
           let str = String(data: data, encoding: .utf8) {
            log("REQ \(url.path) since=\(since) until=\(until ?? -1) ownerHex=\(ownerHex.prefix(8))")
            client.send(text: str)
        }
    }

    /// Signs and sends a NIP-42 AUTH response (kind 22242). The "relay" tag must exactly
    /// match the endpoint's own scheme+host+path (khatru validates against its own base
    /// URL with http(s) swapped for ws(s)) — the endpoint string is already normalized to
    /// wss:// by performSync, so it can be used directly.
    private func sendAuthResponse(challenge: String, to client: WebSocketClient, endpoint: String) {
        let tags: [[String]] = [
            ["relay", endpoint],
            ["challenge", challenge]
        ]
        Task {
            guard let authEvent = await NostrService.shared.signEventAsync(kind: 22242, content: "", tags: tags, forceOwner: true) else {
                log("failed to sign NIP-42 AUTH event for \(endpoint)", level: "WARN")
                return
            }
            let msg: [Any] = ["AUTH", eventToDict(authEvent)]
            if let data = try? JSONSerialization.data(withJSONObject: msg),
               let str = String(data: data, encoding: .utf8) {
                client.send(text: str)
            }
        }
    }

    private func eventToDict(_ event: NostrEvent) -> [String: Any] {
        return [
            "id": event.id,
            "pubkey": event.pubkey,
            "created_at": event.created_at,
            "kind": event.kind,
            "tags": event.tags,
            "content": event.content,
            "sig": event.sig
        ]
    }

    private func processMessage(_ message: String, subId: String, endpoints: [String], index: Int, since: Int64) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 2,
              let type = json[0] as? String else { return }

        if type == "CLOSED" {
            let reason = json[safe: 2] as? String ?? "unknown"
            log("subscription closed by \(endpoints[safe: index] ?? "relay"): \(reason)", level: "WARN")

            // An "auth-required" close is expected for the REQ we send before the AUTH
            // challenge arrives on /private and /chat — the message sink's AUTH handler
            // re-sends the REQ once authenticated, so don't treat this one as fatal.
            // Anything else genuinely has nothing left to page; move on now rather than
            // burning the 60s safety timeout.
            guard !reason.hasPrefix("auth-required") else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.client != nil else { return }
                self.client?.disconnect()
                self.syncFromEndpoints(endpoints, index: index + 1, since: since)
            }
            return
        }

        if type == "EOSE" {
            // Send CLOSE for this subscription
            let closeMsg: [Any] = ["CLOSE", subId]
            if let d = try? JSONSerialization.data(withJSONObject: closeMsg),
               let s = String(data: d, encoding: .utf8) {
                DispatchQueue.main.async { [weak self] in self?.client?.send(text: s) }
            }

            // Capture page state before the async hop (we're on processingQueue here)
            let pageCount = bgAccumulator.pageEventCount
            let gotFullPage = pageCount >= pageLimit
            let oldest = bgAccumulator.pageOldestTimestamp

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                self.client?.disconnect()

                // If we received a full page and haven't walked back to `since` yet, paginate
                if gotFullPage && oldest > since && oldest != Int64.max {
                    self.log("full page (\(pageCount) events), paginating with until=\(oldest - 1)")
                    self.syncFromEndpoints(endpoints, index: index, since: since, until: oldest - 1)
                } else {
                    // Fewer than a full page — this endpoint is exhausted, move on
                    self.log("endpoint done (\(pageCount) events on last page), next endpoint")
                    self.syncFromEndpoints(endpoints, index: index + 1, since: since)
                }
            }
            return
        }

        guard type == "EVENT", json.count >= 3,
              let eventDict = json[2] as? [String: Any],
              let eventId = eventDict["id"] as? String else { return }

        // Deduplicate globally across all pages/endpoints
        if bgAccumulator.syncedEventIds.contains(eventId) { return }
        bgAccumulator.syncedEventIds.insert(eventId)

        let endpoint = endpoints[index]
        let dbKey: String
        if endpoint.hasSuffix("/inbox") {
            dbKey = "inbox"
        } else if endpoint.hasSuffix("/private") {
            dbKey = "private"
        } else if endpoint.hasSuffix("/chat") {
            dbKey = "chat"
        } else {
            dbKey = "outbox"
        }
        bgAccumulator.pendingEvents[dbKey, default: []].append(eventDict)

        // Track page-level stats for pagination decision
        bgAccumulator.pageEventCount += 1
        if let ts = eventDict["created_at"] as? Int64 {
            if ts < bgAccumulator.pageOldestTimestamp { bgAccumulator.pageOldestTimestamp = ts }
        } else if let ts = eventDict["created_at"] as? Int {
            let ts64 = Int64(ts)
            if ts64 < bgAccumulator.pageOldestTimestamp { bgAccumulator.pageOldestTimestamp = ts64 }
        }

        // Capture count on processingQueue before dispatching to main
        let count = bgAccumulator.syncedEventIds.count
        DispatchQueue.main.async { [weak self] in
            self?.notesSynced = count
            self?.syncStatus = "Synced \(count) notes..."
        }
    }

    
    // MARK: - Finish & Inject into Local Relay

    private func finishSync() {
        // Safely capture accumulated events from the background queue
        let capturedEvents = processingQueue.sync { bgAccumulator.pendingEvents }
        let totalCount = capturedEvents.values.reduce(0) { $0 + $1.count }
        guard totalCount > 0 else {
            isSyncing = false
            syncStatus = "Already up to date"
            lastSyncDate = Date()
            log("no new events found on Mac relay")
            return
        }

        syncStatus = "Saving \(totalCount) events to local relay..."

        log("injecting \(totalCount) events into local relay")

        let localURLStr = ConfigService.shared.config.nostrURL
        guard let outboxURL = URL(string: localURLStr),
              let inboxURL = URL(string: localURLStr + "/inbox"),
              let privateURL = URL(string: localURLStr + "/private"),
              let chatURL = URL(string: localURLStr + "/chat") else {
            syncStatus = "Error: Invalid local relay URL"
            isSyncing = false
            return
        }

        let outboxEvents = capturedEvents["outbox"] ?? []
        let inboxEvents = capturedEvents["inbox"] ?? []
        let privateEvents = capturedEvents["private"] ?? []
        let chatEvents = capturedEvents["chat"] ?? []

        log("routing \(outboxEvents.count) to outbox, \(inboxEvents.count) to inbox, \(privateEvents.count) to private, \(chatEvents.count) to chat")

        var maxTimestamp: Int64 = self.lastSyncTimestamp

        // Track max timestamp across all events
        for (_, events) in capturedEvents {
            for eventDict in events {
                if let ts = eventDict["created_at"] as? Int64 {
                    maxTimestamp = max(maxTimestamp, ts)
                } else if let ts = eventDict["created_at"] as? Int {
                    maxTimestamp = max(maxTimestamp, Int64(ts))
                }
            }
        }

        // Inject endpoints sequentially to avoid overwhelming the local relay
        let endpoints: [(events: [[String: Any]], url: URL, label: String)] = [
            (outboxEvents, outboxURL, "outbox"),
            (inboxEvents, inboxURL, "inbox"),
            (privateEvents, privateURL, "private"),
            (chatEvents, chatURL, "chat")
        ]

        // Each injected inbox/chat event fires its own NOTIFY marker as the local
        // relay processes it (see haven-go's inboxRelay/chatRelay StoreEvent hooks) —
        // without batching, catching up after being away would flood the user with
        // one notification per event instead of a single "N new notifications" summary.
        LocalNotificationService.shared.beginCatchUpBatch()

        Task {
            defer {
                // Safety: guarantee isSyncing resets even if something fails
                if isSyncing {
                    isSyncing = false
                    syncStatus = "Sync interrupted"
                }
                LocalNotificationService.shared.endCatchUpBatch()
            }

            for endpoint in endpoints {
                guard !endpoint.events.isEmpty else { continue }
                syncStatus = "Saving \(endpoint.label) (\(endpoint.events.count) events)..."
                await injectEvents(endpoint.events, to: endpoint.url, label: endpoint.label)
            }

            let nowTimestamp = Int64(Date().timeIntervalSince1970)
            lastSyncTimestamp = min(maxTimestamp, nowTimestamp)
            isSyncing = false
            lastSyncDate = Date()
            syncStatus = "Synced \(totalCount) notes"

            log("sync complete — \(totalCount) events injected, maxTimestamp=\(maxTimestamp)")

            NotificationCenter.default.post(name: .macRelaySyncComplete, object: nil)
        }
    }

    /// Injects events into a single local relay endpoint with throttled batches.
    private func injectEvents(_ events: [[String: Any]], to url: URL, label: String) async {
        let client = WebSocketClient()
        client.isTemporary = true

        // Wait for connection
        let connected = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var resumed = false
            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    guard !resumed else { return }
                    if state == .connected {
                        resumed = true
                        continuation.resume(returning: true)
                    } else if state == .error {
                        resumed = true
                        continuation.resume(returning: false)
                    }
                }
                .store(in: &self.cancellables)

            client.connect(url: url)

            // Timeout after 10 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: false)
            }
        }

        guard connected else {
            log("\(label) connection failed, skipping", level: "WARN")
            client.disconnect()
            return
        }

        // Send events in batches of 20 with a pause between each batch
        let batchSize = 20
        for i in stride(from: 0, to: events.count, by: batchSize) {
            let end = min(i + batchSize, events.count)
            for eventDict in events[i..<end] {
                let msg: [Any] = ["EVENT", eventDict]
                if let data = try? JSONSerialization.data(withJSONObject: msg),
                   let str = String(data: data, encoding: .utf8) {
                    client.send(text: str)
                }
            }
            // Throttle between batches to let the relay process writes
            if end < events.count {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }

        // Give the relay a moment to finish processing the last batch
        try? await Task.sleep(nanoseconds: 500_000_000)
        client.disconnect()

        log("\(label) injection done (\(events.count) events)")
    }
}

// MARK: - Notification

extension Notification.Name {
    static let macRelaySyncComplete = Notification.Name("macRelaySyncComplete")
}
