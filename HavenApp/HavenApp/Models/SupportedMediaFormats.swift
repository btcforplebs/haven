import Foundation

// MARK: - Supported Media Formats

/// Single source of truth for all media format metadata in the app.
/// Every extension list, MIME mapping, and media-URL regex should derive
/// from these tables rather than maintaining independent copies.
enum SupportedMediaFormats {

    // MARK: Media Category

    enum Category: String, CaseIterable {
        case image
        case gif       // Separated from image for rendering decisions
        case video
        case audio
    }

    // MARK: Format Definitions

    /// Each entry maps one file extension to its canonical MIME type and category.
    struct FormatEntry {
        let ext: String          // Lowercase, no dot (e.g. "jpg")
        let mime: String         // Canonical MIME (e.g. "image/jpeg")
        let category: Category
    }

    /// The master table.
    static let all: [FormatEntry] = [
        // Images
        FormatEntry(ext: "jpg",  mime: "image/jpeg",    category: .image),
        FormatEntry(ext: "jpeg", mime: "image/jpeg",    category: .image),
        FormatEntry(ext: "png",  mime: "image/png",     category: .image),
        FormatEntry(ext: "webp", mime: "image/webp",    category: .image),
        FormatEntry(ext: "heic", mime: "image/heic",    category: .image),
        FormatEntry(ext: "avif", mime: "image/avif",    category: .image),
        FormatEntry(ext: "tiff", mime: "image/tiff",    category: .image),
        FormatEntry(ext: "tif",  mime: "image/tiff",    category: .image),
        FormatEntry(ext: "svg",  mime: "image/svg+xml", category: .image),

        // GIF (distinct category for animated rendering)
        FormatEntry(ext: "gif",  mime: "image/gif",     category: .gif),

        // Video
        FormatEntry(ext: "mp4",  mime: "video/mp4",        category: .video),
        FormatEntry(ext: "mov",  mime: "video/quicktime",   category: .video),
        FormatEntry(ext: "webm", mime: "video/webm",        category: .video),
        FormatEntry(ext: "m4v",  mime: "video/mp4",         category: .video),
        FormatEntry(ext: "hevc", mime: "video/mp4",         category: .video),
        FormatEntry(ext: "h265", mime: "video/mp4",         category: .video),
        FormatEntry(ext: "avi",  mime: "video/x-msvideo",   category: .video),
        FormatEntry(ext: "mkv",  mime: "video/x-matroska",  category: .video),

        // Audio
        FormatEntry(ext: "mp3",  mime: "audio/mpeg",  category: .audio),
        FormatEntry(ext: "wav",  mime: "audio/wav",   category: .audio),
        FormatEntry(ext: "m4a",  mime: "audio/mp4",   category: .audio),
        FormatEntry(ext: "aac",  mime: "audio/mp4",   category: .audio),
        FormatEntry(ext: "flac", mime: "audio/flac",  category: .audio),
        FormatEntry(ext: "ogg",  mime: "audio/ogg",   category: .audio),
        FormatEntry(ext: "opus", mime: "audio/opus",  category: .audio),
    ]

    // MARK: Derived Lookups

    /// Extension -> MIME type.  e.g. "jpg" -> "image/jpeg"
    static let mimeForExtension: [String: String] = {
        Dictionary(all.map { ($0.ext, $0.mime) }, uniquingKeysWith: { first, _ in first })
    }()

    /// MIME type -> preferred extension.  e.g. "video/quicktime" -> "mov"
    /// When multiple extensions share a MIME (jpg/jpeg), the first in `all` wins.
    static let extensionForMime: [String: String] = {
        var dict: [String: String] = [:]
        for entry in all where dict[entry.mime] == nil {
            dict[entry.mime] = entry.ext
        }
        // Common non-standard aliases some servers return
        dict["video/mov"] = "mov"
        dict["audio/mpeg"] = "mp3"
        dict["audio/x-m4a"] = "m4a"
        dict["audio/aac"] = "aac"
        return dict
    }()

    /// Extension -> Category.  e.g. "mp4" -> .video
    static let categoryForExtension: [String: Category] = {
        Dictionary(all.map { ($0.ext, $0.category) }, uniquingKeysWith: { first, _ in first })
    }()

    // MARK: Extension Sets

    static let videoExtensions: Set<String> = {
        Set(all.filter { $0.category == .video }.map { $0.ext })
    }()

    static let imageExtensions: Set<String> = {
        Set(all.filter { $0.category == .image }.map { $0.ext })
    }()

    static let audioExtensions: Set<String> = {
        Set(all.filter { $0.category == .audio }.map { $0.ext })
    }()

    static let allExtensions: Set<String> = {
        Set(all.map { $0.ext })
    }()

    /// Image extensions + gif.
    static let imageOrGifExtensions: Set<String> = {
        Set(all.filter { $0.category == .image || $0.category == .gif }.map { $0.ext })
    }()

    // MARK: Classification Helpers

    static func category(forExtension ext: String) -> Category? {
        categoryForExtension[ext.lowercased()]
    }

    static func category(forMime mime: String) -> Category? {
        let lower = mime.lowercased()
        if lower.contains("image/gif") { return .gif }
        if lower.hasPrefix("image/")   { return .image }
        if lower.hasPrefix("video/")   { return .video }
        if lower.hasPrefix("audio/")   { return .audio }
        return nil
    }

    static func mime(forExtension ext: String) -> String? {
        mimeForExtension[ext.lowercased()]
    }

    static func `extension`(forMime mime: String) -> String? {
        // Strip parameters (e.g. "video/mp4; codecs=avc1" → "video/mp4")
        let base = mime.lowercased().split(separator: ";").first.map(String.init) ?? mime.lowercased()
        return extensionForMime[base.trimmingCharacters(in: .whitespaces)]
    }

    // MARK: Regex

    /// All supported extensions as a regex alternation: "aac|avif|avi|..."
    static let extensionAlternation: String = {
        all.map { $0.ext }.sorted().joined(separator: "|")
    }()

    /// Matches media URLs ending in a known extension, plus Blossom hash URLs.
    static let mediaURLRegex: NSRegularExpression? = {
        let pattern = #"(https?://\S+?\.(?:"# + extensionAlternation + #")(?:\?\S+)?)|(https?://\S+?/blossom/[a-f0-9]{64})|(https?://\S+?/[a-f0-9]{64})"#
        return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    /// Matches only extension-based media URLs (no Blossom groups).
    static let mediaExtensionRegex: NSRegularExpression? = {
        let pattern = #"https?://\S+?\.(?:"# + extensionAlternation + #")(?:\?\S+)?"#
        return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()
}

// MARK: - URL Convenience

extension URL {
    var mediaCategory: SupportedMediaFormats.Category? {
        SupportedMediaFormats.category(forExtension: self.pathExtension)
    }

    var isVideo: Bool {
        SupportedMediaFormats.videoExtensions.contains(self.pathExtension.lowercased())
    }

    var isAudio: Bool {
        SupportedMediaFormats.audioExtensions.contains(self.pathExtension.lowercased())
    }

    var isImage: Bool {
        let ext = self.pathExtension.lowercased()
        if SupportedMediaFormats.imageOrGifExtensions.contains(ext) { return true }
        // Blossom hash fallback: extensionless 64-char hex paths
        if ext.isEmpty {
            let last = self.lastPathComponent
            return last.range(of: #"^[a-f0-9]{64}$"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return false
    }

    var isGIF: Bool {
        self.pathExtension.lowercased() == "gif"
    }

    var isWebP: Bool {
        self.pathExtension.lowercased() == "webp"
    }
}
