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
    private var syncedEventIds = Set<String>()
    private var pendingEvents: [String: [[String: Any]]] = [
        "outbox": [],
        "inbox": [],
        "private": [],
        "chat": []
    ]
    private let processingQueue = DispatchQueue(label: "com.haven.mac-relay-sync", qos: .userInitiated)

    // BadgerDB (Haven's default) enforces MaxLimit=1000. The query engine honours
    // filter.Limit only when 0 < filter.Limit <= MaxLimit; values above MaxLimit
    // silently fall back to MaxLimit/4 = 250.  Requesting exactly 1000 therefore
    // maximises events per page on BadgerDB, and still fits within LMDB's 1500 cap.
    private let pageLimit = 1000
    // Per-page tracking — reset at the start of each REQ.
    private var pageEventCount: Int = 0
    private var pageOldestTimestamp: Int64 = Int64.max
    
    /// UserDefaults key for the last successful sync timestamp
    private let lastSyncKey = "com.haven.macRelay.lastSyncTimestamp"
    
    /// The timestamp of the last successful sync (persisted across app launches)
    var lastSyncTimestamp: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: lastSyncKey)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: lastSyncKey) }
    }
    
    // MARK: - Public API
    
    /// Syncs missed notes from the configured Mac relay.
    /// Call this on app foreground or after the local relay finishes booting.
    func syncIfConfigured() {
        let macURL = ConfigService.shared.config.macRelayURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !macURL.isEmpty else { return }
        guard !isSyncing else {
            #if DEBUG
            print("MacRelaySyncService: Already syncing, skipping")
            #endif
            return
        }
        
        // Ensure local relay is ready before syncing
        guard RelayProcessManager.shared.isRunning,
              !RelayProcessManager.shared.isBooting else {
            #if DEBUG
            print("MacRelaySyncService: Local relay not ready, deferring sync")
            #endif
            return
        }
        
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
        pendingEvents = [
            "outbox": [],
            "inbox": [],
            "private": [],
            "chat": []
        ]
        syncedEventIds.removeAll()
        syncStatus = "Connecting to Mac relay..."
        
        // Use provided timestamp or 1-hour overlap from last known sync
        let startTime = fromTimestamp ?? max(0, lastSyncTimestamp - 3600)
        
        #if DEBUG
        print("MacRelaySyncService: Starting sync from \(endpoints) since timestamp \(startTime) (original last sync: \(lastSyncTimestamp))")
        #endif
        
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

        // Reset page-level tracking for this request
        pageEventCount = 0
        pageOldestTimestamp = Int64.max

        let wsClient = WebSocketClient()
        wsClient.isTemporary = true
        self.client = wsClient

        let subId = "mac-sync-\(UUID().uuidString.prefix(6))"

        wsClient.messageSubject
            .receive(on: processingQueue)
            .sink { [weak self] message in
                self?.processMessage(message, subId: subId, endpoints: endpoints, index: index, since: since)
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
                    #if DEBUG
                    print("MacRelaySyncService: Connection error to \(endpoint)")
                    #endif
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
                #if DEBUG
                print("MacRelaySyncService: Timeout for \(endpoint) until=\(until ?? -1), advancing")
                #endif
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
            #if DEBUG
            print("MacRelaySyncService: REQ \(url.path) since=\(since) until=\(until ?? -1) ownerHex=\(ownerHex.prefix(8))")
            #endif
            client.send(text: str)
        }
    }

    private func processMessage(_ message: String, subId: String, endpoints: [String], index: Int, since: Int64) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 2,
              let type = json[0] as? String else { return }

        if type == "EOSE" {
            // Send CLOSE for this subscription
            let closeMsg: [Any] = ["CLOSE", subId]
            if let d = try? JSONSerialization.data(withJSONObject: closeMsg),
               let s = String(data: d, encoding: .utf8) {
                DispatchQueue.main.async { [weak self] in self?.client?.send(text: s) }
            }

            // Capture page state before the async hop
            let gotFullPage = pageEventCount >= pageLimit
            let oldest = pageOldestTimestamp

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                self.client?.disconnect()

                // If we received a full page and haven't walked back to `since` yet, paginate
                if gotFullPage && oldest > since && oldest != Int64.max {
                    #if DEBUG
                    print("MacRelaySyncService: Full page (\(self.pageEventCount) events), paginating with until=\(oldest - 1)")
                    #endif
                    self.syncFromEndpoints(endpoints, index: index, since: since, until: oldest - 1)
                } else {
                    // Fewer than a full page — this endpoint is exhausted, move on
                    #if DEBUG
                    print("MacRelaySyncService: Endpoint done (\(self.pageEventCount) events on last page), next endpoint")
                    #endif
                    self.syncFromEndpoints(endpoints, index: index + 1, since: since)
                }
            }
            return
        }

        guard type == "EVENT", json.count >= 3,
              let eventDict = json[2] as? [String: Any],
              let eventId = eventDict["id"] as? String else { return }

        // Deduplicate globally across all pages/endpoints
        if syncedEventIds.contains(eventId) { return }
        syncedEventIds.insert(eventId)

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
        pendingEvents[dbKey, default: []].append(eventDict)

        // Track page-level stats for pagination decision
        pageEventCount += 1
        if let ts = eventDict["created_at"] as? Int64 {
            if ts < pageOldestTimestamp { pageOldestTimestamp = ts }
        } else if let ts = eventDict["created_at"] as? Int {
            let ts64 = Int64(ts)
            if ts64 < pageOldestTimestamp { pageOldestTimestamp = ts64 }
        }

        DispatchQueue.main.async { [weak self] in
            self?.notesSynced = self?.syncedEventIds.count ?? 0
            self?.syncStatus = "Synced \(self?.notesSynced ?? 0) notes..."
        }
    }

    
    // MARK: - Finish & Inject into Local Relay

    private func finishSync() {
        let totalCount = pendingEvents.values.reduce(0) { $0 + $1.count }
        guard totalCount > 0 else {
            isSyncing = false
            syncStatus = "Already up to date"
            lastSyncDate = Date()
            #if DEBUG
            print("MacRelaySyncService: No new events found on Mac relay.")
            #endif
            return
        }

        syncStatus = "Saving \(totalCount) events to local relay..."

        #if DEBUG
        print("MacRelaySyncService: Injecting \(totalCount) events into local relay")
        #endif

        let localURLStr = ConfigService.shared.config.nostrURL
        guard let outboxURL = URL(string: localURLStr),
              let inboxURL = URL(string: localURLStr + "/inbox"),
              let privateURL = URL(string: localURLStr + "/private"),
              let chatURL = URL(string: localURLStr + "/chat") else {
            syncStatus = "Error: Invalid local relay URL"
            isSyncing = false
            return
        }

        let outboxEvents = pendingEvents["outbox"] ?? []
        let inboxEvents = pendingEvents["inbox"] ?? []
        let privateEvents = pendingEvents["private"] ?? []
        let chatEvents = pendingEvents["chat"] ?? []

        #if DEBUG
        print("MacRelaySyncService: Routing \(outboxEvents.count) to outbox, \(inboxEvents.count) to inbox, \(privateEvents.count) to private, \(chatEvents.count) to chat")
        #endif

        var maxTimestamp: Int64 = self.lastSyncTimestamp

        // Track max timestamp across all events
        for (_, events) in pendingEvents {
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

        Task {
            defer {
                // Safety: guarantee isSyncing resets even if something fails
                if isSyncing {
                    isSyncing = false
                    syncStatus = "Sync interrupted"
                }
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

            #if DEBUG
            print("MacRelaySyncService: Sync complete — \(totalCount) events injected, maxTimestamp=\(maxTimestamp)")
            #endif

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
            #if DEBUG
            print("MacRelaySyncService: \(label) connection failed, skipping")
            #endif
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

        #if DEBUG
        print("MacRelaySyncService: \(label) injection done (\(events.count) events)")
        #endif
    }
}

// MARK: - Notification

extension Notification.Name {
    static let macRelaySyncComplete = Notification.Name("macRelaySyncComplete")
}
