import Foundation

// MARK: - Tile fetching
//
// The half of the media problem the app cannot solve for us.
//
// Blossom blobs living on this device are shrunk by the app and handed over as
// bytes (see NVThumbnails). Media hosted anywhere else has no local file to
// shrink, so it has to come down the wire — and the only place a widget may do
// that is its timeline provider, which is async and does have a network. The
// widget's `body` has neither, which is why `AsyncImage` renders a placeholder
// and never resolves.
//
// Everything here is therefore best-effort and firmly time-boxed: a widget that
// takes too long to produce a timeline gets its entry dropped, so a slow host
// must cost us that tile, never the whole grid.
enum NVTileFetcher {
    /// Per-request ceiling. Short on purpose: the tile is decoration, and a
    /// widget refresh that stalls is worse than a gap in the grid.
    private static let timeout: TimeInterval = 4

    /// Tiles fetched per refresh. Each one is a request and a decode inside a
    /// process with a hard memory ceiling.
    private static let maxConcurrentFetches = 12

    static func fetch(_ tiles: [NVWidgetSnapshot.MediaTile], maxPixel: Int = 160) async -> [String: Data] {
        let wanted = tiles.filter { isFetchable($0.url) }.prefix(maxConcurrentFetches)
        guard !wanted.isEmpty else { return [:] }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.requestCachePolicy = .returnCacheDataElseLoad
        let session = URLSession(configuration: config)

        return await withTaskGroup(of: (String, Data)?.self) { group in
            for tile in wanted {
                group.addTask {
                    guard let (data, response) = try? await session.data(from: tile.url),
                          (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                          let shrunk = NVDownsample.tile(from: data, maxPixel: maxPixel)
                    else { return nil }
                    return (tile.id, shrunk)
                }
            }
            var out: [String: Data] = [:]
            for await result in group {
                if let (id, data) = result { out[id] = data }
            }
            return out
        }
    }

    /// The relay serves its own blobs from 127.0.0.1, and the relay is only up
    /// while the app is running — which is precisely when nobody is looking at
    /// the Home Screen. Those tiles come from the handoff or not at all, so
    /// spending a 4 s timeout on them would just delay every other tile.
    private static func isFetchable(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host != "127.0.0.1" && host != "localhost" && host != "::1"
    }
}
