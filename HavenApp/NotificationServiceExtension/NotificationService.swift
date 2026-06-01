import UserNotifications

class NotificationService: UNNotificationServiceExtension {

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    private static let fallbackRelays = [
        "wss://relay.damus.io",
        "wss://relay.primal.net",
        "wss://nos.lol"
    ]

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        guard let content = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        let userInfo = request.content.userInfo
        guard let authorPubkey = userInfo["author_pubkey"] as? String else {
            contentHandler(content)
            return
        }

        Task {
            let (displayName, pictureURL) = await fetchProfileMetadata(pubkey: authorPubkey)

            // Replace the truncated npub in the title with the resolved display name
            if let name = displayName {
                // The server sends titles like "npub1abc…xyz4 mentioned you"
                // Replace everything before the first known action verb
                let title = content.title
                let actionKeywords = [" mentioned you", " replied to your note", " reposted your note", " liked your note", " disliked your note", " reacted ", " Zap from "]
                for keyword in actionKeywords {
                    if let range = title.range(of: keyword) {
                        content.title = name + String(title[range.lowerBound...])
                        break
                    }
                }
                // Handle "DM from npub…" pattern
                if content.title.hasPrefix("DM from ") {
                    content.title = "DM from \(name)"
                }
                // Handle "⚡ Zap from npub…" pattern
                if content.title.hasPrefix("⚡ Zap from ") {
                    content.title = "⚡ Zap from \(name)"
                }
            }

            if let pictureURL = pictureURL,
               let attachment = await downloadAttachment(from: pictureURL) {
                content.attachments = [attachment]
            }
            contentHandler(content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler = contentHandler, let content = bestAttemptContent {
            contentHandler(content)
        }
    }

    // MARK: - Profile Fetch via Relay WebSocket

    /// Fetches the author's kind-0 metadata, trying multiple relays as fallback.
    private func fetchProfileMetadata(pubkey: String) async -> (displayName: String?, pictureURL: URL?) {
        for relay in Self.fallbackRelays {
            let result = await fetchProfileFromRelay(relay, pubkey: pubkey)
            if result.displayName != nil {
                return result
            }
        }
        return (nil, nil)
    }

    /// Attempts to fetch profile metadata from a single relay with timeout.
    private func fetchProfileFromRelay(_ relay: String, pubkey: String) async -> (displayName: String?, pictureURL: URL?) {
        guard let url = URL(string: relay) else { return (nil, nil) }

        do {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 10
            let session = URLSession(configuration: config)
            let ws = session.webSocketTask(with: url)
            ws.resume()
            defer { ws.cancel(with: .goingAway, reason: nil) }

            // Send REQ for kind 0 (metadata) by this author
            let subId = "profile-\(pubkey.prefix(8))"
            let req = "[\"REQ\",\"\(subId)\",{\"kinds\":[0],\"authors\":[\"\(pubkey)\"],\"limit\":1}]"
            try await ws.send(.string(req))

            // Read messages until we get an EVENT or EOSE
            for _ in 0..<5 {
                let message = try await ws.receive()
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                   let type = json.first as? String, type == "EVENT",
                   json.count >= 3,
                   let event = json[2] as? [String: Any],
                   let contentStr = event["content"] as? String,
                   let contentData = contentStr.data(using: .utf8),
                   let metadata = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any] {
                    // Close subscription
                    let close = "[\"CLOSE\",\"\(subId)\"]"
                    try? await ws.send(.string(close))

                    // Resolve display name: prefer display_name, fall back to name
                    let displayName = (metadata["display_name"] as? String)
                        .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                        ?? (metadata["name"] as? String)
                            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }

                    let pictureURL = (metadata["picture"] as? String).flatMap { URL(string: $0) }
                    return (displayName, pictureURL)
                }
            }
        } catch {
            // Relay fetch failed — try next relay
        }
        return (nil, nil)
    }

    // MARK: - Image Download

    private func downloadAttachment(from url: URL) async -> UNNotificationAttachment? {
        do {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5
            config.timeoutIntervalForResource = 5
            let session = URLSession(configuration: config)

            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  !data.isEmpty else { return nil }

            // Determine file extension from content type
            let ext: String
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
            if contentType.contains("png") {
                ext = "png"
            } else if contentType.contains("gif") {
                ext = "gif"
            } else if contentType.contains("webp") {
                ext = "webp"
            } else {
                ext = "jpg"
            }

            let tempDir = FileManager.default.temporaryDirectory
            let fileURL = tempDir.appendingPathComponent(UUID().uuidString + ".\(ext)")
            try data.write(to: fileURL)

            return try UNNotificationAttachment(identifier: "profile-image", url: fileURL)
        } catch {
            return nil
        }
    }
}
