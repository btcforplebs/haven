import SwiftUI
import Foundation

public struct NostrContentFormatter {
    // Pre-compiled regex patterns — avoids re-creating on every format() call
    private static let npubRegex = try! NSRegularExpression(pattern: "nostr:(npub1[a-z0-9]+)")
    private static let nprofileRegex = try! NSRegularExpression(pattern: "nostr:(nprofile1[a-z0-9]+)")
    private static let noteRegex = try! NSRegularExpression(pattern: "nostr:(note1[a-z0-9]+)")
    private static let neventRegex = try! NSRegularExpression(pattern: "nostr:(nevent1[a-z0-9]+)")
    /// Matches bare HTTP(S) URLs that are NOT already inside markdown link syntax.
    private static let httpURLRegex = try! NSRegularExpression(pattern: #"(?<![(\[])https?://[^\s<>\")\]]*[^\s<>\")\].,;:!?'\"]"#, options: .caseInsensitive)

    // Result cache — keyed on content + mediaURLs count + hideQuotes. Note content is immutable
    // so the formatted result can be safely reused.
    private static let cache = NSCache<NSString, Box<AttributedString>>()

    private final class Box<T> {
        let value: T
        init(_ value: T) { self.value = value }
    }

    @MainActor
    public static func format(_ content: String, mediaURLs: [URL] = [], hideQuotes: Bool = false) -> AttributedString {
        let key = "\(content.hashValue)_\(mediaURLs.count)_\(hideQuotes)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached.value
        }
        let result = formatUncached(content, mediaURLs: mediaURLs, hideQuotes: hideQuotes)
        cache.setObject(Box(result), forKey: key)
        return result
    }

    @MainActor
    private static func formatUncached(_ content: String, mediaURLs: [URL], hideQuotes: Bool) -> AttributedString {
        var text = content

        // Strip bare image/video URLs from text (they'll show as thumbnails)
        for url in mediaURLs {
            text = text.replacingOccurrences(of: url.absoluteString, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Resolve nostr:npub and nostr:nprofile
        text = replaceWithLinks(in: text, regex: npubRegex, template: "nostr:$1")
        text = replaceWithLinks(in: text, regex: nprofileRegex, template: "nostr:$1")

        // Resolve nostr:note and nostr:nevent
        if hideQuotes {
            text = noteRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            text = neventRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        } else {
            text = replaceWithLinks(in: text, regex: noteRegex, template: "nostr:$1", label: "Quote")
            text = replaceWithLinks(in: text, regex: neventRegex, template: "nostr:$1", label: "Quote")
        }

        // Convert bare HTTP(S) URLs to clickable markdown links
        text = linkifyURLs(in: text)

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            var attrString = try AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))

            // Clear any embedded foreground colors so SwiftUI's .foregroundColor() takes effect
            for run in attrString.runs {
                if run.foregroundColor != nil {
                    let range = run.range
                    attrString[range].foregroundColor = nil
                }
            }

            return attrString
        } catch {
            return AttributedString(text)
        }
    }

    /// Converts bare HTTP(S) URLs to markdown links so they become tappable in the attributed string.
    /// Skips URLs already wrapped in markdown link syntax (e.g. `[label](url)`).
    private static func linkifyURLs(in text: String) -> String {
        let nsString = text as NSString
        let matches = httpURLRegex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))

        var result = text
        var offset = 0

        for match in matches {
            let range = match.range
            let urlString = nsString.substring(with: range)

            // Skip if this URL is already inside a markdown link: [text](URL)
            let adjustedStart = range.location + offset
            if adjustedStart > 1 {
                let before = (result as NSString).substring(with: NSRange(location: adjustedStart - 1, length: 1))
                if before == "(" { continue }
            }

            // Show a short display label: domain + truncated path
            let displayLabel: String
            if let url = URL(string: urlString), let host = url.host {
                let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                let path = url.path
                if path.count > 1 && path != "/" {
                    let truncatedPath = path.count > 20 ? String(path.prefix(20)) + "..." : path
                    displayLabel = domain + truncatedPath
                } else {
                    displayLabel = domain
                }
            } else {
                displayLabel = urlString
            }

            let markdownLink = "[\(displayLabel)](\(urlString))"
            let fullRange = NSRange(location: adjustedStart, length: range.length)
            result = (result as NSString).replacingCharacters(in: fullRange, with: markdownLink)
            offset += markdownLink.count - range.length
        }

        return result
    }

    @MainActor
    private static func replaceWithLinks(in text: String, regex: NSRegularExpression, template: String, label: String? = nil) -> String {
        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))

        var result = text
        var offset = 0

        for match in matches {
            let fullRange = NSRange(location: match.range.location + offset, length: match.range.length)
            let matchedValue = nsString.substring(with: match.range(at: 1))

            var hexPubkey: String?

            if matchedValue.hasPrefix("npub1") {
                if let decoded = Bech32.decode(matchedValue) {
                    hexPubkey = decoded.hexString
                }
            } else if matchedValue.hasPrefix("nprofile1") {
                if let decoded = Bech32.decode(matchedValue) {
                    // TLV parsing for nprofile: Type 0 is the pubkey (32 bytes)
                    var data = decoded.data
                    while data.count >= 2 {
                        let type = data.removeFirst()
                        let length = Int(data.removeFirst())
                        if data.count >= length {
                            let value = data.prefix(length)
                            if type == 0 && length == 32 {
                                hexPubkey = value.map { String(format: "%02x", $0) }.joined()
                                break
                            }
                            data.removeFirst(length)
                        } else {
                            break
                        }
                    }
                }
            }

            var displayLabel: String
            if let label = label {
                displayLabel = label
            } else if let hex = hexPubkey {
                if let name = NostrService.shared.profiles[hex]?.bestName {
                    displayLabel = "@\(name)"
                } else {
                    // Use truncated npub as placeholder and trigger fetch
                    let preview = matchedValue.prefix(12)
                    displayLabel = "@\(preview)..."
                    NostrService.shared.fetchMissingProfiles(for: [hex])
                }
            } else {
                // Fallback for failed decodes OR note1/nevent1
                let preview = matchedValue.prefix(12)
                displayLabel = "@\(preview)..."
            }

            // Add markdown bolding so it's even more noticeable
            let markdownLink = "**[\(displayLabel)](nostr:\(matchedValue))**"
            let prevLength = fullRange.length
            result = (result as NSString).replacingCharacters(in: fullRange, with: markdownLink)
            offset += markdownLink.count - prevLength
        }

        return result
    }
}
