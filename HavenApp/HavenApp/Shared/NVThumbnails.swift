import Foundation
import ImageIO
import Security
import UniformTypeIdentifiers

// MARK: - Widget thumbnails
//
// Why the widgets cannot just load their own images.
//
// A widget draws in one static pass: there is no run loop waiting around to
// finish a download, so `AsyncImage` in a widget body renders its placeholder
// and stops. Anything a widget shows has to exist before the body runs.
//
// The media in this app is worse than remote: it is served by the relay inside
// the app, on 127.0.0.1. That relay is only up while the app is running, which
// is exactly when nobody is looking at the Home Screen. So the widget cannot
// fetch it at draw time, and often cannot fetch it at refresh time either.
//
// The app therefore shrinks its media to tiles and hands the bytes across,
// alongside the snapshot but in a separate keychain item: the small widgets
// (Sats, Lock Screen, Quick Actions) read the snapshot many times a day and
// should not pay for image bytes they never draw.

/// Downsampled tiles, keyed by the media id they belong to.
struct NVThumbnailBundle: Codable, Equatable {
    var generatedAt: Date
    var images: [String: Data]

    static let empty = NVThumbnailBundle(generatedAt: .distantPast, images: [:])
}

enum NVThumbnailStore {
    /// Total bytes of JPEG allowed across the handoff. A keychain item is a poor
    /// place for image data, so this is a ceiling, not a target: ~18 tiles at
    /// 160px land around 90 KB.
    static let budget = 180 * 1024

    private static let service = "to.nostrvault.widget"
    private static let account = "thumbs.v1"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: NVSharedStore.accessGroup,
        ]
    }

    static func load() -> NVThumbnailBundle? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(NVThumbnailBundle.self, from: data)
    }

    @discardableResult
    static func save(_ bundle: NVThumbnailBundle) -> Bool {
        guard let data = try? JSONEncoder().encode(bundle) else { return false }

        // Same accessibility as the snapshot: widgets refresh while the device
        // is locked, and a tile that cannot be read then is a blank widget.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var insert = baseQuery
        insert.merge(attributes) { _, new in new }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

// MARK: - Downsampling

/// Shrinks image data to a tile without ever decoding the full-size image.
///
/// `kCGImageSourceCreateThumbnailFromImageAlways` matters here: a lot of camera
/// media carries an embedded thumbnail that is smaller than the tile we want,
/// and using it would give us a soft, upscaled square. The extension also has a
/// hard memory ceiling, which is the other reason this never goes through
/// `UIImage(data:)`.
enum NVDownsample {
    static func tile(from data: Data, maxPixel: Int, quality: Double = 0.55) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return encode(source: source, maxPixel: maxPixel, quality: quality)
    }

    static func tile(fileURL: URL, maxPixel: Int, quality: Double = 0.55) -> Data? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return encode(source: source, maxPixel: maxPixel, quality: quality)
    }

    private static func encode(source: CGImageSource, maxPixel: Int, quality: Double) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
