import Foundation

/// Detects media types for URLs, especially those without file extensions (like Blossom hashes)
class MediaTypeDetector {
    static let shared = MediaTypeDetector()

    // Cache content types to avoid repeated network requests
    private var contentTypeCache: [URL: String] = [:]
    private let cacheLock = NSLock()

    // Coalescing: multiple callers requesting the same URL share one HEAD request
    private var inFlightDetections: [URL: [CheckedContinuation<String?, Never>]] = [:]
    private let inFlightLock = NSLock()

    private init() {}

    /// Synchronously get cached content type, or nil if not cached
    func getCachedContentType(for url: URL) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return contentTypeCache[url]
    }

    /// Async detect content type via HTTP HEAD request with request coalescing
    func detectContentTypeAsync(for url: URL) async -> String? {
        // Check cache first
        if let cached = getCachedContentType(for: url) {
            return cached
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            inFlightLock.lock()
            if inFlightDetections[url] != nil {
                // Already in flight — join the waiter list
                inFlightDetections[url]?.append(continuation)
                inFlightLock.unlock()
                return
            }
            // We're the leader — reserve the slot
            inFlightDetections[url] = []
            inFlightLock.unlock()

            Task.detached(priority: .utility) { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "HEAD"
                request.timeoutInterval = 5.0

                var detectedType: String?
                do {
                    let (_, response) = try await MediaSessionService.shared.session.data(for: request)
                    if let httpResponse = response as? HTTPURLResponse,
                       httpResponse.statusCode == 200,
                       let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") {
                        detectedType = contentType
                    }
                } catch {
                    // Timeout or network error — leave detectedType nil
                }

                // Cache the result
                if let type = detectedType {
                    self.cacheLock.withLock {
                        self.contentTypeCache[url] = type
                    }
                }

                // Broadcast to all waiters
                let waiters = self.inFlightLock.withLock {
                    let w = self.inFlightDetections[url] ?? []
                    self.inFlightDetections.removeValue(forKey: url)
                    return w
                }

                continuation.resume(returning: detectedType)
                for waiter in waiters {
                    waiter.resume(returning: detectedType)
                }
            }
        }
    }

    /// Callback-based wrapper for backward compatibility with existing callers
    func detectContentType(for url: URL, completion: @escaping (String?) -> Void) {
        // Check cache first (fast path, avoids task creation)
        if let cached = getCachedContentType(for: url) {
            completion(cached)
            return
        }

        Task {
            let result = await detectContentTypeAsync(for: url)
            await MainActor.run {
                completion(result)
            }
        }
    }

    /// Check if a content type indicates an image
    func isImageContentType(_ contentType: String) -> Bool {
        let lowercased = contentType.lowercased()
        return lowercased.hasPrefix("image/")
    }

    /// Check if a content type indicates a video
    func isVideoContentType(_ contentType: String) -> Bool {
        let lowercased = contentType.lowercased()
        return lowercased.hasPrefix("video/")
    }

    /// Check if a content type indicates a GIF
    func isGIFContentType(_ contentType: String) -> Bool {
        let lowercased = contentType.lowercased()
        return lowercased.contains("image/gif")
    }

    /// Determine if URL is likely a Blossom hash (64 hex chars, possibly with extension)
    func isBlossom(url: URL) -> Bool {
        let last = url.lastPathComponent
        let pattern = #"^[a-f0-9]{64}(\.[a-z0-9]+)?$"#
        return last.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Pre-fetch content types for an array of URLs in the background
    func prefetchContentTypes(for urls: [URL]) {
        for url in urls {
            // Only prefetch for extensionless or Blossom URLs
            if url.pathExtension.isEmpty || isBlossom(url: url) {
                Task {
                    _ = await detectContentTypeAsync(for: url)
                }
            }
        }
    }
}
