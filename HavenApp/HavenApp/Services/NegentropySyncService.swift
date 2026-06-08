#if os(iOS)
import Foundation
import Combine

// MARK: - NegentropySyncService

@MainActor
class NegentropySyncService: NSObject, URLSessionDelegate {
    static let shared = NegentropySyncService()

    @Published private(set) var isSyncing = false

    private let syncKinds = [1, 6, 7, 30023, 9735]
    private let cooldownInterval: TimeInterval = 30
    private let receiveTimeout: TimeInterval = 15

    private var lastSyncDate: Date?
    private var syncTask: Task<Void, Never>?

    // MARK: - Public API

    func sync() {
        guard !isSyncing,
              RelayProcessManager.shared.isRunning else { return }

        let config = ConfigService.shared.config
        let macURL = config.macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !macURL.isEmpty else { return }

        if let last = lastSyncDate, Date().timeIntervalSince(last) < cooldownInterval { return }

        isSyncing = true
        syncTask = Task { [weak self] in
            await self?.performSync()
        }
    }

    func cancel() {
        syncTask?.cancel()
        syncTask = nil
        isSyncing = false
    }

    // MARK: - URLSessionDelegate (trust self-signed certs for local relay)

    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host
        if host == "127.0.0.1" || host == "localhost" {
            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }

    // MARK: - Sync Orchestration

    private func performSync() async {
        defer {
            isSyncing = false
            lastSyncDate = Date()
        }

        let config = ConfigService.shared.config
        let localURL = config.nostrURL
        let macWssURL = config.macRelayWssURL
        guard !macWssURL.isEmpty else { return }

        print("[NegSync] Starting sync — local: \(localURL), mac: \(macWssURL)")

        // 1. Scan local relay outbox + inbox in parallel
        async let outboxScan = scanLocalRelay(urlString: localURL)
        async let inboxScan = scanLocalRelay(urlString: localURL + "/inbox")
        let outboxVector = await outboxScan
        let inboxVector = await inboxScan
        guard !Task.isCancelled else { return }

        outboxVector.seal()
        inboxVector.seal()

        let localOutboxCount = outboxVector.size
        let localInboxCount = inboxVector.size
        print("[NegSync] Local scan: \(localOutboxCount) outbox, \(localInboxCount) inbox events")

        // 2. Fast path: if local relay is empty, skip Negentropy and do a direct
        //    time-bounded REQ from the Mac relay. Negentropy is efficient for diffs
        //    but wasteful when we know we need everything.
        if localOutboxCount == 0 && localInboxCount == 0 {
            print("[NegSync] Local relay empty — using direct fetch (last 7 days)")
            let since = Int64(Date().timeIntervalSince1970) - 7 * 86400
            await directFetch(macRelayURL: macWssURL, since: since)
            await directFetch(macRelayURL: macWssURL + "/inbox", since: since)
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(3))
            NotificationCenter.default.post(name: .feedInjectionComplete, object: nil)
            print("[NegSync] Direct fetch complete")
            return
        }

        // 3. Normal path: Negentropy reconciliation (outbox + inbox in parallel)
        async let outboxReconcile = reconcile(localVector: outboxVector, macRelayURL: macWssURL)
        async let inboxReconcile = reconcile(localVector: inboxVector, macRelayURL: macWssURL + "/inbox")
        let outboxHaveNots = await outboxReconcile
        let inboxHaveNots = await inboxReconcile
        guard !Task.isCancelled else { return }

        let total = outboxHaveNots.count + inboxHaveNots.count
        print("[NegSync] Missing: \(outboxHaveNots.count) outbox, \(inboxHaveNots.count) inbox")

        // 4. Fetch missing events from Mac relay
        if !outboxHaveNots.isEmpty {
            fetchMissing(ids: outboxHaveNots, fromURL: macWssURL)
        }
        if !inboxHaveNots.isEmpty {
            fetchMissing(ids: inboxHaveNots, fromURL: macWssURL + "/inbox")
        }

        // 5. Notify UI to refresh if we fetched anything
        if total > 0 {
            try? await Task.sleep(for: .seconds(3))
            NotificationCenter.default.post(name: .feedInjectionComplete, object: nil)
        }

        print("[NegSync] Complete")
    }

    // MARK: - Phase 1: Scan Local Relay

    private func scanLocalRelay(urlString: String) async -> NegentropyVector {
        let vector = NegentropyVector()
        guard let url = URL(string: urlString) else { return vector }

        let session = URLSession(
            configuration: .default,
            delegate: self,
            delegateQueue: nil
        )
        let task = session.webSocketTask(with: url)
        task.resume()

        let subId = "negscan-\(UUID().uuidString.prefix(6))"

        // Send REQ
        let filter: [String: Any] = ["kinds": syncKinds]
        let req: [Any] = ["REQ", subId, filter]
        guard let reqData = try? JSONSerialization.data(withJSONObject: req),
              let reqStr = String(data: reqData, encoding: .utf8) else {
            session.invalidateAndCancel()
            return vector
        }

        do {
            try await task.send(.string(reqStr))
        } catch {
            print("[NegSync] Scan send error: \(error.localizedDescription)")
            session.invalidateAndCancel()
            return vector
        }

        // Receive events until EOSE
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline && !Task.isCancelled {
            guard let text = await receiveText(task, timeout: receiveTimeout) else { break }

            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let type = json.first as? String else { continue }

            switch type {
            case "EVENT":
                if json.count >= 3,
                   let eventDict = json[2] as? [String: Any],
                   let id = eventDict["id"] as? String,
                   let createdAt = eventDict["created_at"] as? NSNumber {
                    vector.insert(timestamp: createdAt.int64Value, id: id)
                }
            case "EOSE":
                // Close subscription and disconnect
                let close: [Any] = ["CLOSE", subId]
                if let d = try? JSONSerialization.data(withJSONObject: close),
                   let s = String(data: d, encoding: .utf8) {
                    try? await task.send(.string(s))
                }
                task.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
                return vector
            default:
                break
            }
        }

        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        return vector
    }

    // MARK: - Fast Path: Direct Fetch (empty local relay)

    /// Fetches recent events directly from the Mac relay via REQ when the local
    /// relay is empty. Much faster than Negentropy for the initial sync because
    /// there's no reconciliation overhead — we know we need everything.
    private func directFetch(macRelayURL: String, since: Int64) async {
        guard let url = URL(string: macRelayURL) else { return }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        task.resume()

        let subId = "negdirect-\(UUID().uuidString.prefix(6))"
        let filter: [String: Any] = ["kinds": syncKinds, "since": since]
        let req: [Any] = ["REQ", subId, filter]
        guard let reqData = try? JSONSerialization.data(withJSONObject: req),
              let reqStr = String(data: reqData, encoding: .utf8) else {
            session.invalidateAndCancel()
            return
        }

        do {
            try await task.send(.string(reqStr))
        } catch {
            print("[NegSync] Direct fetch send error: \(error.localizedDescription)")
            session.invalidateAndCancel()
            return
        }

        // Collect event IDs, then fetch full events via the existing injection pipeline
        var eventIds: [String] = []
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline && !Task.isCancelled {
            guard let text = await receiveText(task, timeout: receiveTimeout) else { break }

            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let type = json.first as? String else { continue }

            switch type {
            case "EVENT":
                if json.count >= 3,
                   let eventDict = json[2] as? [String: Any],
                   let id = eventDict["id"] as? String {
                    eventIds.append(id)
                }
            case "EOSE":
                let close: [Any] = ["CLOSE", subId]
                if let d = try? JSONSerialization.data(withJSONObject: close),
                   let s = String(data: d, encoding: .utf8) {
                    try? await task.send(.string(s))
                }
                task.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
                print("[NegSync] Direct fetch got \(eventIds.count) events from \(macRelayURL)")
                if !eventIds.isEmpty {
                    fetchMissing(ids: eventIds, fromURL: macRelayURL)
                }
                return
            default:
                break
            }
        }

        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        if !eventIds.isEmpty {
            fetchMissing(ids: eventIds, fromURL: macRelayURL)
        }
    }

    // MARK: - Phase 2: Negentropy Reconciliation

    private func reconcile(localVector: NegentropyVector, macRelayURL: String) async -> [String] {
        guard let url = URL(string: macRelayURL) else { return [] }

        let neg = Negentropy(storage: localVector, frameSizeLimit: negentropyFrameSizeLimit)
        let initialMsg = neg.start()

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        task.resume()

        let subId = "neg-\(UUID().uuidString.prefix(8))"
        var allHaveNots: [String] = []

        // Send NEG-OPEN: ["NEG-OPEN", subId, filter, hexMsg]
        let filter: [String: Any] = ["kinds": syncKinds]
        let negOpen: [Any] = ["NEG-OPEN", subId, filter, initialMsg]
        guard let openData = try? JSONSerialization.data(withJSONObject: negOpen),
              let openStr = String(data: openData, encoding: .utf8) else {
            session.invalidateAndCancel()
            return []
        }

        do {
            try await task.send(.string(openStr))
        } catch {
            print("[NegSync] NEG-OPEN send error: \(error.localizedDescription)")
            session.invalidateAndCancel()
            return []
        }

        // Exchange NEG-MSG rounds
        exchangeLoop: while !Task.isCancelled {
            guard let text = await receiveText(task, timeout: receiveTimeout) else {
                print("[NegSync] Receive timeout/error during reconciliation")
                break
            }

            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let type = json.first as? String else { continue }

            switch type {
            case "NEG-MSG":
                guard json.count >= 3,
                      let msgSubId = json[1] as? String, msgSubId == subId,
                      let hexMsg = json[2] as? String else { continue }

                do {
                    let result = try neg.reconcile(hexMsg)
                    allHaveNots.append(contentsOf: result.haveNots)

                    if let nextMsg = result.nextMessage {
                        // Send next round
                        let negMsg: [Any] = ["NEG-MSG", subId, nextMsg]
                        if let d = try? JSONSerialization.data(withJSONObject: negMsg),
                           let s = String(data: d, encoding: .utf8) {
                            try await task.send(.string(s))
                        }
                    } else {
                        // Reconciliation complete — send NEG-CLOSE
                        sendNegClose(task, subId: subId)
                        break exchangeLoop
                    }
                } catch {
                    print("[NegSync] Reconcile error: \(error)")
                    sendNegClose(task, subId: subId)
                    break exchangeLoop
                }

            case "NEG-ERROR", "NEG-ERR":
                let reason = json.count >= 3 ? (json[2] as? String ?? "unknown") : "unknown"
                print("[NegSync] Server error: \(reason)")
                break exchangeLoop

            default:
                // Ignore non-NEG messages (NOTICE, etc.)
                continue
            }
        }

        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        return allHaveNots
    }

    // MARK: - Phase 3: Fetch Missing Events

    private func fetchMissing(ids: [String], fromURL: String) {
        guard let url = URL(string: fromURL) else { return }
        let batchSize = 50
        for start in stride(from: 0, to: ids.count, by: batchSize) {
            let end = min(start + batchSize, ids.count)
            let batch = Array(ids[start..<end])
            NostrService.shared.fetchNotesByIds(batch, from: [url])
        }
    }

    // MARK: - Helpers

    private func receiveText(_ task: URLSessionWebSocketTask, timeout: TimeInterval) async -> String? {
        do {
            return try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    let message = try await task.receive()
                    if case .string(let text) = message {
                        return text
                    }
                    return nil
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw CancellationError()
                }

                guard let result = try await group.next() else { return nil }
                group.cancelAll()
                return result
            }
        } catch {
            return nil
        }
    }

    private func sendNegClose(_ task: URLSessionWebSocketTask, subId: String) {
        let negClose: [Any] = ["NEG-CLOSE", subId]
        if let d = try? JSONSerialization.data(withJSONObject: negClose),
           let s = String(data: d, encoding: .utf8) {
            task.send(.string(s)) { _ in }
        }
    }
}
#endif
