import Foundation
import Combine

@MainActor
class StatsService: ObservableObject {
    static let shared = StatsService()
    
    @Published var storageSize: Int64 = 0
    @Published var blossomSize: Int64 = 0
    @Published var cacheSize: Int64 = 0
    @Published var thumbnailSize: Int64 = 0
    @Published var loadedEventsCount: Int = UserDefaults.standard.integer(forKey: "haven.stats.eventCount")
    @Published var isUpdatingCount: Bool = false
    
    private var nostrService = NostrService.shared
    private var relayManager = RelayProcessManager.shared
    private var cancellables = Set<AnyCancellable>()
    
    // Tracking for real-time updates
    private var baseDbCount: Int = 0
    private var baseRelayNotesStored: Int = 0
    /// Prevents the observer from overwriting the UserDefaults-loaded count
    /// before `refreshStats` has fetched the real DB count at least once.
    private var hasEstablishedBaseline: Bool = false
    /// Counts consecutive refreshes where the confirmed DB count was lower than
    /// the persisted floor. After enough consistent reads the floor is assumed
    /// stale (e.g. after a database prune) and is replaced with the real count.
    private var consecutiveLowerCount: Int = 0
    
    init() {
        // Observe RelayProcessManager for new incoming events (real-time updates)
        relayManager.$eventsStored
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (newNoteCount: Int) in
                guard let self = self, self.hasEstablishedBaseline else { return }
                
                // If eventsStored was reset (e.g. after import),
                // realign the baselines so the diff tracking starts fresh.
                if newNoteCount < self.baseRelayNotesStored {
                    self.baseRelayNotesStored = 0
                    self.baseDbCount = self.loadedEventsCount
                }
                
                // diff is how many new events came in since we last fetched the DB count
                let diff = newNoteCount - self.baseRelayNotesStored
                if diff >= 0 {
                    let newCount = self.baseDbCount + diff
                    self.loadedEventsCount = newCount
                    UserDefaults.standard.set(newCount, forKey: "haven.stats.eventCount")
                }
            }
            .store(in: &cancellables)
        
        // Refresh counts from database when feed injection completes
        NotificationCenter.default.publisher(for: .feedInjectionComplete)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let config = ConfigService.shared.config
                let urlString = config.relayURL.isEmpty ? "localhost:\(config.relayPort)" : config.relayURL
                self.refreshStats(relayURLString: urlString)
            }
            .store(in: &cancellables)
    }
    
    func refreshStats(relayURLString: String? = nil) {
        if isUpdatingCount { return }
        self.isUpdatingCount = true
        
        Task { @MainActor in
            defer { self.isUpdatingCount = false }
            
            let relayDir = ConfigService.shared.relayDataDir
            let blossomDir = relayDir.appendingPathComponent("blossom")
            let cacheDir = relayDir.appendingPathComponent("cache")
            let thumbDir = relayDir.appendingPathComponent("thumbnails")

            // Perform heavy I/O in a background task
            let (storage, blossom, cache, thumbnails) = await Task.detached(priority: .userInitiated) {
                let s = self.calculateSize(of: relayDir)
                let b = self.calculateSize(of: blossomDir)
                let c = self.calculateSize(of: cacheDir)
                let t = self.calculateSize(of: thumbDir)
                return (s, b, c, t)
            }.value

            self.storageSize = storage
            self.blossomSize = blossom
            self.cacheSize = cache
            self.thumbnailSize = thumbnails
            
            // Fetch persistent count if URL provided
            if let _ = relayURLString {
                let config = ConfigService.shared.config
                
                // Construct internal URLs for Outbox (root) and Inbox (tagged notes)
                // We ALWAYS use 127.0.0.1 for the internal stats fetch to bypass loopback/domain issues
                // even if config.nostrURL is set to a public domain.
                // macOS relay runs plain HTTP/WS; iOS relay runs HTTPS/WSS (self-signed cert)
                #if os(macOS)
                let baseURLString = "ws://127.0.0.1:\(config.relayPort)"
                #else
                let baseURLString = "wss://127.0.0.1:\(config.relayPort)"
                #endif
                guard let baseURL = URL(string: baseURLString) else {
                    #if DEBUG
                    print("StatsService: ❌ Invalid baseURL for stats: \(baseURLString)")
                    #endif
                    return
                }
                
                let relayURLs = [
                    baseURL,
                    baseURL.appendingPathComponent("inbox"),
                    baseURL.appendingPathComponent("private"),
                    baseURL.appendingPathComponent("chat")
                ]
                
                #if DEBUG
                print("StatsService: 🔄 Starting full count refresh from: \(relayURLs.map { $0.absoluteString })")
                #endif
                
                // Now on MainActor, we can safely access RelayProcessManager.shared
                if RelayProcessManager.shared.isRunning {
                    #if DEBUG
                    print("StatsService: 📡 Calling fetchCount for all events...")
                    #endif
                    
                    var count = await self.nostrService.fetchCount(from: relayURLs, filter: [:])
                    
                    #if DEBUG
                    print("StatsService: 📩 fetchCount returned: events=\(String(describing: count))")
                    #endif
                    
                    // If we get 0 but previously had a count, retry once after a short delay
                    if (count ?? 0) == 0 && (self.loadedEventsCount > 0 || !RelayProcessManager.shared.isBooting) {
                        #if DEBUG
                        print("StatsService: ⚠️ Fetch returned 0 for events. Retrying once...")
                        #endif
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        count = await self.nostrService.fetchCount(from: relayURLs, filter: [:])
                    }
                    
                    // Guard: Only update events if we have a valid non-zero count, or if our current count is 0
                    if let confirmedCount = count, (confirmedCount > 0 || self.loadedEventsCount == 0) {
                        let effectiveCount: Int
                        if confirmedCount >= self.loadedEventsCount {
                            // Normal case: count grew or stayed the same
                            effectiveCount = confirmedCount
                            self.consecutiveLowerCount = 0
                        } else {
                            // Confirmed count is lower than persisted floor.
                            // A single low read is likely a stale/incomplete relay
                            // response, but 3+ consecutive low reads means the
                            // floor itself is stale (e.g. after a database prune).
                            self.consecutiveLowerCount += 1
                            if self.consecutiveLowerCount >= 3 {
                                effectiveCount = confirmedCount
                                self.consecutiveLowerCount = 0
                            } else {
                                effectiveCount = self.loadedEventsCount
                            }
                        }
                        #if DEBUG
                        print("StatsService: ✨ Total aggregated events count: \(confirmedCount)" +
                              (effectiveCount != confirmedCount ? " (floored to \(effectiveCount))" : ""))
                        #endif
                        self.baseDbCount = effectiveCount
                        self.baseRelayNotesStored = RelayProcessManager.shared.eventsStored
                        self.hasEstablishedBaseline = true

                        self.loadedEventsCount = effectiveCount
                        UserDefaults.standard.set(effectiveCount, forKey: "haven.stats.eventCount")
                    } else {
                        #if DEBUG
                        print("StatsService: ❌ Fetch failed or returned 0 for events. Keeping old count: \(self.loadedEventsCount)")
                        #endif
                    }
                } else {
                    #if DEBUG
                    print("StatsService: ⏭️ Skipping fetch - relay not running (State: \(RelayProcessManager.shared.state))")
                    #endif
                    
                    // If it's NOT running but we are still updating, let's at least clear the spinner if count is 0
                    if self.loadedEventsCount == 0 {
                        // Keep it 0 but stop the loading state
                    }
                }
            } else {
                #if DEBUG
                print("StatsService: ℹ️ refreshStats called without relayURLString, only updated disk sizes.")
                #endif
            }
        }
    }
    
    /// Fetches event counts per kind from the local relay. Uses one WebSocket per relay
    /// endpoint and pipelines all COUNT requests through it to avoid hitting the connection
    /// rate limiter. Returns a dictionary mapping kind number to count, plus the total under key -1.
    func fetchCountsByKind() async -> [Int: Int] {
        let config = ConfigService.shared.config
        #if os(macOS)
        let baseURLString = "ws://127.0.0.1:\(config.relayPort)"
        #else
        let baseURLString = "wss://127.0.0.1:\(config.relayPort)"
        #endif
        guard let baseURL = URL(string: baseURLString) else { return [:] }

        let relayURLs = [
            baseURL,
            baseURL.appendingPathComponent("inbox"),
            baseURL.appendingPathComponent("private"),
            baseURL.appendingPathComponent("chat")
        ]

        // Common Nostr kinds to query — covers profile, social, media, lists, long-form, zaps, DMs
        let kindsToQuery = [
            0, 1, 3, 4, 5, 6, 7, 8, 9, 16,
            1059, 1063, 1311, 1808,
            9734, 9735,
            10000, 10001, 10002, 10003, 10005, 10006, 10015, 10030,
            30000, 30001, 30002, 30008, 30009, 30023, 30024, 30030, 30078
        ]

        var results: [Int: Int] = [:]
        var allEndpointsResponded = true

        // One connection per URL, pipeline all COUNT requests through it
        await withTaskGroup(of: [Int: Int]?.self) { group in
            for url in relayURLs {
                group.addTask {
                    return await Self.fetchKindCounts(url: url, kinds: kindsToQuery)
                }
            }
            for await partial in group {
                if let partial = partial {
                    for (kind, count) in partial {
                        results[kind, default: 0] += count
                    }
                } else {
                    allEndpointsResponded = false
                }
            }
        }

        // Discard partial results to avoid showing fluctuating breakdown counts
        if !allEndpointsResponded {
            #if DEBUG
            print("StatsService: Not all endpoints responded for kind breakdown — returning empty")
            #endif
            return [:]
        }

        return results
    }

    /// Opens a single WebSocket to the relay URL and sends one COUNT per kind plus a total.
    /// Returns kind -> count, with the grand total under key -1. Returns nil on connection failure.
    private static func fetchKindCounts(url: URL, kinds: [Int]) async -> [Int: Int]? {
        let client = await MainActor.run { () -> WebSocketClient in
            let c = WebSocketClient()
            c.isTemporary = true
            return c
        }
        await MainActor.run { client.connect(url: url) }

        // Wait for connection (5s timeout)
        var connectCancellable: AnyCancellable?
        let didConnect = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resumed = false
            connectCancellable = client.$connectionState
                .first(where: { $0 == .connected || $0 == .error })
                .timeout(.seconds(5), scheduler: DispatchQueue.main)
                .sink { completion in
                    guard !resumed else { return }
                    resumed = true
                    // Timeout or upstream completion without value = failure
                    cont.resume(returning: false)
                } receiveValue: { state in
                    guard !resumed else { return }
                    resumed = true
                    cont.resume(returning: state == .connected)
                }
        }
        connectCancellable?.cancel()
        guard didConnect else {
            await MainActor.run { client.disconnect() }
            return nil
        }

        // Assign a unique sub ID per kind (and -1 for total)
        var subIdToKind: [String: Int] = [:]
        var pending: Set<String> = []
        let totalSubId = "count-total-\(UUID().uuidString.prefix(6))"
        subIdToKind[totalSubId] = -1
        pending.insert(totalSubId)
        for kind in kinds {
            let subId = "count-k\(kind)-\(UUID().uuidString.prefix(6))"
            subIdToKind[subId] = kind
            pending.insert(subId)
        }

        var results: [Int: Int] = [:]

        var messageCancellable: AnyCancellable?
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var resumed = false
            messageCancellable = client.messageSubject
                .receive(on: DispatchQueue.main)
                .timeout(.seconds(20), scheduler: DispatchQueue.main)
                .sink { _ in
                    // Timeout or upstream completion
                    guard !resumed else { return }
                    resumed = true
                    cont.resume()
                } receiveValue: { msg in
                    guard let data = msg.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          json.count >= 3,
                          let type = json[0] as? String,
                          let subId = json[1] as? String,
                          type == "COUNT",
                          let kind = subIdToKind[subId],
                          let payload = json[2] as? [String: Any],
                          let rawCount = payload["count"] else { return }

                    let extracted: Int
                    if let i = rawCount as? Int { extracted = i }
                    else if let d = rawCount as? Double { extracted = Int(d) }
                    else if let n = rawCount as? NSNumber { extracted = n.intValue }
                    else if let s = rawCount as? String, let i = Int(s) { extracted = i }
                    else { extracted = 0 }

                    results[kind] = extracted
                    pending.remove(subId)

                    // Only resume once all responses received
                    if pending.isEmpty {
                        guard !resumed else { return }
                        resumed = true
                        cont.resume()
                    }
                }

            // Fire all COUNT requests
            DispatchQueue.main.async {
                let totalReq: [Any] = ["COUNT", totalSubId, [:] as [String: Any]]
                if let d = try? JSONSerialization.data(withJSONObject: totalReq),
                   let s = String(data: d, encoding: .utf8) {
                    client.send(text: s)
                }
                for kind in kinds {
                    let subId = subIdToKind.first(where: { $0.value == kind })?.key ?? ""
                    let req: [Any] = ["COUNT", subId, ["kinds": [kind]] as [String: Any]]
                    if let d = try? JSONSerialization.data(withJSONObject: req),
                       let s = String(data: d, encoding: .utf8) {
                        client.send(text: s)
                    }
                }
            }
        }
        messageCancellable?.cancel()

        await MainActor.run { client.disconnect() }
        return results
    }

    nonisolated private func calculateSize(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            // Skip the blossom directory for the main storage count to avoid double counting if desired?
            // "Storage Used" usually implies *total* used by the app.
            // "Media Storage" is a subset.
            // I'll count total for storage, and specific for media.
            if let attributes = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
               let size = attributes.totalFileAllocatedSize {
                total += Int64(size)
            }
        }
        return total
    }
    
    var formattedStorageSize: String {
        ByteCountFormatter.string(fromByteCount: storageSize, countStyle: .file)
    }
    
    var formattedBlossomSize: String {
        ByteCountFormatter.string(fromByteCount: blossomSize, countStyle: .file)
    }
    
    var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: cacheSize + thumbnailSize, countStyle: .file)
    }

    var formattedThumbnailSize: String {
        ByteCountFormatter.string(fromByteCount: thumbnailSize, countStyle: .file)
    }

    struct CacheBreakdown {
        var imageCount: Int = 0
        var imageSize: Int64 = 0
        var videoCount: Int = 0
        var videoSize: Int64 = 0
        var otherCount: Int = 0
        var otherSize: Int64 = 0
        var thumbnailCount: Int = 0
        var thumbnailSize: Int64 = 0
        var oldestFile: Date?
        var newestFile: Date?
    }

    nonisolated func calculateCacheBreakdown(relayDir: URL) -> CacheBreakdown {
        let cacheDir = relayDir.appendingPathComponent("cache")
        let thumbDir = relayDir.appendingPathComponent("thumbnails")

        var breakdown = CacheBreakdown()
        let fm = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey, .contentModificationDateKey]

        if let contents = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: Array(resourceKeys)) {
            for fileURL in contents {
                guard let vals = try? fileURL.resourceValues(forKeys: resourceKeys) else { continue }
                if vals.isDirectory == true { continue }
                let size = Int64(vals.totalFileAllocatedSize ?? 0)
                if let modified = vals.contentModificationDate {
                    if breakdown.oldestFile == nil || modified < breakdown.oldestFile! { breakdown.oldestFile = modified }
                    if breakdown.newestFile == nil || modified > breakdown.newestFile! { breakdown.newestFile = modified }
                }
                switch Self.detectFileType(at: fileURL) {
                case .image:
                    breakdown.imageCount += 1
                    breakdown.imageSize += size
                case .video:
                    breakdown.videoCount += 1
                    breakdown.videoSize += size
                case .other:
                    breakdown.otherCount += 1
                    breakdown.otherSize += size
                }
            }
        }

        if let thumbContents = try? fm.contentsOfDirectory(at: thumbDir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .contentModificationDateKey]) {
            for fileURL in thumbContents {
                guard let vals = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .contentModificationDateKey]) else { continue }
                let size = Int64(vals.totalFileAllocatedSize ?? 0)
                if let modified = vals.contentModificationDate {
                    if breakdown.oldestFile == nil || modified < breakdown.oldestFile! { breakdown.oldestFile = modified }
                    if breakdown.newestFile == nil || modified > breakdown.newestFile! { breakdown.newestFile = modified }
                }
                breakdown.thumbnailCount += 1
                breakdown.thumbnailSize += size
            }
        }

        return breakdown
    }

    private enum CachedFileType { case image, video, other }

    nonisolated private static func detectFileType(at url: URL) -> CachedFileType {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .other }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count >= 3 else { return .other }

        // JPEG: FF D8 FF
        if header[0] == 0xFF && header[1] == 0xD8 && header[2] == 0xFF { return .image }
        // PNG: 89 50 4E 47
        if header.count >= 4 && header[0] == 0x89 && header[1] == 0x50 && header[2] == 0x4E && header[3] == 0x47 { return .image }
        // GIF: 47 49 46 38
        if header.count >= 4 && header[0] == 0x47 && header[1] == 0x49 && header[2] == 0x46 && header[3] == 0x38 { return .image }
        // WebP: RIFF....WEBP
        if header.count >= 12 && header[0] == 0x52 && header[1] == 0x49 && header[2] == 0x46 && header[3] == 0x46
            && header[8] == 0x57 && header[9] == 0x45 && header[10] == 0x42 && header[11] == 0x50 { return .image }
        // MP4/MOV: ftyp at offset 4
        if header.count >= 8 && header[4] == 0x66 && header[5] == 0x74 && header[6] == 0x79 && header[7] == 0x70 { return .video }
        // WebM/MKV: 1A 45 DF A3
        if header.count >= 4 && header[0] == 0x1A && header[1] == 0x45 && header[2] == 0xDF && header[3] == 0xA3 { return .video }

        return .other
    }

    func fetchBlobList(for hexPubkey: String) async -> [BlobDescriptor] {
        let config = ConfigService.shared.config
        #if os(macOS)
        let baseURLString = "http://127.0.0.1:\(config.relayPort)"
        let session = URLSession.shared
        #else
        let baseURLString = "https://127.0.0.1:\(config.relayPort)"
        let session = URLSession(configuration: .default, delegate: LocalhostTrustDelegate(), delegateQueue: nil)
        #endif
        guard let url = URL(string: "\(baseURLString)/list/\(hexPubkey)") else { return [] }
        guard let (data, _) = try? await session.data(from: url) else { return [] }
        return (try? JSONDecoder().decode([BlobDescriptor].self, from: data)) ?? []
    }
}
