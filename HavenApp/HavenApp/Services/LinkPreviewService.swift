import Foundation

// MARK: - Data Model

struct LinkPreviewMetadata: Codable, Equatable {
    let url: URL
    let title: String?
    let description: String?
    let imageURL: URL?
    let siteName: String?
}

// MARK: - LinkPreviewService

/// Fetches and caches OpenGraph metadata for URLs.
/// Uses the same patterns as MediaTypeDetector: memory cache, disk cache, and request coalescing.
class LinkPreviewService {
    static let shared = LinkPreviewService()

    // In-memory cache (auto-evicts under memory pressure)
    private let memoryCache = NSCache<NSString, Box>()
    // Disk cache directory
    private let cacheDirectory: URL
    // Request coalescing: avoid duplicate fetches for the same URL
    private var inFlightRequests: [URL: [CheckedContinuation<LinkPreviewMetadata?, Never>]] = [:]
    private let lock = NSLock()
    // Negative cache: URLs that returned no useful OG data
    private var failedURLs: Set<String> = []

    private final class Box {
        let value: LinkPreviewMetadata?
        init(_ value: LinkPreviewMetadata?) { self.value = value }
    }

    // OG meta tag patterns
    private static let ogPropertyRegex = try! NSRegularExpression(
        pattern: #"<meta\s+[^>]*property\s*=\s*["']og:(\w+)["'][^>]*content\s*=\s*["']([^"']*)["'][^>]*/?\s*>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let ogContentFirstRegex = try! NSRegularExpression(
        pattern: #"<meta\s+[^>]*content\s*=\s*["']([^"']*)["'][^>]*property\s*=\s*["']og:(\w+)["'][^>]*/?\s*>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let titleRegex = try! NSRegularExpression(
        pattern: #"<title[^>]*>([^<]+)</title>"#,
        options: .caseInsensitive
    )

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbDir = appSupport
            .appendingPathComponent("Haven", isDirectory: true)
            .appendingPathComponent("haven_database", isDirectory: true)
        self.cacheDirectory = dbDir.appendingPathComponent("link_previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        memoryCache.countLimit = 200
    }

    // MARK: - Lock Helpers (synchronous, safe to call from async contexts)

    private func isURLFailed(_ urlString: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return failedURLs.contains(urlString)
    }

    private func markURLFailed(_ urlString: String) {
        lock.lock()
        defer { lock.unlock() }
        failedURLs.insert(urlString)
    }

    /// Returns `true` if the continuation joined an existing in-flight request (caller should just wait).
    /// Returns `false` if the caller is the leader and should start the fetch.
    private func addContinuation(_ continuation: CheckedContinuation<LinkPreviewMetadata?, Never>, for url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if var waiters = inFlightRequests[url] {
            waiters.append(continuation)
            inFlightRequests[url] = waiters
            return true
        }
        inFlightRequests[url] = []
        return false
    }

    private func takeWaiters(for url: URL) -> [CheckedContinuation<LinkPreviewMetadata?, Never>] {
        lock.lock()
        defer { lock.unlock() }
        return inFlightRequests.removeValue(forKey: url) ?? []
    }

    // MARK: - Public API

    /// Fetches OpenGraph metadata for a URL. Returns cached data when available.
    func fetchMetadata(for url: URL) async -> LinkPreviewMetadata? {
        let key = url.absoluteString as NSString

        // 1. Memory cache
        if let cached = memoryCache.object(forKey: key) {
            return cached.value
        }

        // 2. Disk cache
        if let diskCached = loadFromDisk(for: url) {
            memoryCache.setObject(Box(diskCached), forKey: key)
            return diskCached
        }

        // 3. Negative cache check
        if isURLFailed(url.absoluteString) {
            return nil
        }

        // 4. Fetch with coalescing
        return await withCheckedContinuation { continuation in
            let isJoining = addContinuation(continuation, for: url)
            if isJoining { return }

            // We're the leader — start the fetch
            Task.detached(priority: .utility) { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }

                let metadata = await self.fetchOGMetadata(for: url)

                // Cache the result
                self.memoryCache.setObject(Box(metadata), forKey: key)
                if let metadata = metadata {
                    self.saveToDisk(metadata, for: url)
                } else {
                    self.markURLFailed(url.absoluteString)
                }

                // Resume all waiting continuations
                let waiters = self.takeWaiters(for: url)

                continuation.resume(returning: metadata)
                for waiter in waiters {
                    waiter.resume(returning: metadata)
                }
            }
        }
    }

    // MARK: - OG Fetching

    private func fetchOGMetadata(for url: URL) async -> LinkPreviewMetadata? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // Some sites return different content for bots; use a browser-like UA
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await MediaSessionService.shared.session.data(for: request)

            // Only parse HTML responses
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
                  contentType.lowercased().contains("text/html") else {
                return nil
            }

            // Only parse the first 50KB to avoid downloading huge pages
            let limit = min(data.count, 50_000)
            let htmlData = data.prefix(limit)

            guard let html = String(data: htmlData, encoding: .utf8)
                    ?? String(data: htmlData, encoding: .isoLatin1) else {
                return nil
            }

            return parseOGTags(from: html, sourceURL: url)
        } catch {
            return nil
        }
    }

    private func parseOGTags(from html: String, sourceURL: URL) -> LinkPreviewMetadata? {
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        var ogData: [String: String] = [:]

        // Parse <meta property="og:X" content="Y">
        for match in Self.ogPropertyRegex.matches(in: html, range: range) {
            let property = ns.substring(with: match.range(at: 1)).lowercased()
            let content = ns.substring(with: match.range(at: 2))
            if !content.isEmpty {
                ogData[property] = content
            }
        }

        // Parse <meta content="Y" property="og:X"> (reversed attribute order)
        for match in Self.ogContentFirstRegex.matches(in: html, range: range) {
            let content = ns.substring(with: match.range(at: 1))
            let property = ns.substring(with: match.range(at: 2)).lowercased()
            if !content.isEmpty && ogData[property] == nil {
                ogData[property] = content
            }
        }

        // Fallback: <title> tag
        var fallbackTitle: String?
        if let match = Self.titleRegex.firstMatch(in: html, range: range) {
            fallbackTitle = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let title = ogData["title"] ?? fallbackTitle
        let description = ogData["description"]
        let siteName = ogData["site_name"]

        // Require at least a title for a useful preview
        guard title != nil else { return nil }

        var imageURL: URL?
        if let imageString = ogData["image"], !imageString.isEmpty {
            if imageString.hasPrefix("http") {
                imageURL = URL(string: imageString)
            } else if imageString.hasPrefix("//") {
                imageURL = URL(string: "https:" + imageString)
            } else if imageString.hasPrefix("/") {
                // Relative URL — resolve against source
                var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
                components?.path = imageString
                components?.query = nil
                imageURL = components?.url
            }
        }

        return LinkPreviewMetadata(
            url: sourceURL,
            title: title,
            description: description,
            imageURL: imageURL,
            siteName: siteName
        )
    }

    // MARK: - Disk Cache

    private func cacheFilePath(for url: URL) -> URL {
        let hash = url.absoluteString.data(using: .utf8)!
            .map { String(format: "%02x", $0) }.joined()
        let filename = String(hash.prefix(64)) // Truncate for filesystem sanity
        return cacheDirectory.appendingPathComponent(filename + ".json")
    }

    private func loadFromDisk(for url: URL) -> LinkPreviewMetadata? {
        let path = cacheFilePath(for: url)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }

        // Expire after 7 days
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) > 7 * 24 * 3600 {
            try? FileManager.default.removeItem(at: path)
            return nil
        }

        guard let data = try? Data(contentsOf: path),
              let metadata = try? JSONDecoder().decode(LinkPreviewMetadata.self, from: data) else {
            return nil
        }
        return metadata
    }

    private func saveToDisk(_ metadata: LinkPreviewMetadata, for url: URL) {
        let path = cacheFilePath(for: url)
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: path, options: .atomic)
    }
}
