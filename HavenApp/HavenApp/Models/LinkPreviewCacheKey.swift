import Foundation
import CryptoKit

/// The on-disk filename a cached link preview is stored under.
///
/// It has to be a real digest of the whole URL. The first version took hex of
/// the URL's own bytes and truncated it to 64 characters — which is the first
/// 32 characters of the URL, not a hash — so every TestFlight invite, every
/// GitHub PR and every YouTube video shared one cache entry, and the preview
/// you saw was whichever of them was fetched first.
enum LinkPreviewCacheKey {
    static func filename(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".json"
    }
}
