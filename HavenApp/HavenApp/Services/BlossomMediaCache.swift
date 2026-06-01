import Foundation
import SwiftUI

/// Singleton cache for blossom media items. Persists across tab switches and
/// background/foreground cycles so the media grid doesn't need to rescan the
/// filesystem every time the view appears.
@MainActor
class BlossomMediaCache: ObservableObject {
    static let shared = BlossomMediaCache()

    @Published var items: [MediaItem] = []
    @Published var isScanning: Bool = false

    /// Timestamp of the last completed filesystem scan.
    var lastScanDate: Date?

    private init() {}

    /// Returns true if the cache was populated recently enough to skip a rescan.
    /// Default staleness threshold is 5 seconds.
    func isFresh(threshold: TimeInterval = 5.0) -> Bool {
        guard let lastScan = lastScanDate else { return false }
        return Date().timeIntervalSince(lastScan) < threshold
    }
}
