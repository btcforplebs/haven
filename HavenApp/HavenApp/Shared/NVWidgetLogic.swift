import Foundation

// MARK: - Widget layout + budget maths
//
// Pure functions, deliberately free of SwiftUI and WidgetKit so they can be
// unit-tested outside the app (see HavenApp/MediaLogicTests). Everything here
// is arithmetic the widgets would otherwise do inline in a `body`, where it is
// unreachable by a test and easy to get subtly wrong.

/// How many rows a feed widget draws, and how far apart.
///
/// The widget is a fixed box: a fixed row count leaves dead space at the bottom
/// on the taller families, and one row too many clips the last row — the single
/// most common way a feed widget looks broken. So the row count comes from the
/// measured height, and the leftover space is spread between the rows instead
/// of being dumped at the bottom.
enum NVFeedLayout {
    struct Plan: Equatable {
        var rows: Int
        var spacing: CGFloat
    }

    /// - Parameters:
    ///   - availableHeight: the widget's content height, headers included.
    ///   - headerHeight: what the header and its divider consume.
    ///   - rowHeight: the height of one row at the current text size.
    ///   - minSpacing: rows never get closer than this.
    ///   - maxSpacing: rows never get further apart than this, so three notes in
    ///     a large widget read as a list rather than three stranded lines.
    ///   - noteCount: how many notes there actually are to draw.
    static func plan(availableHeight: CGFloat,
                     headerHeight: CGFloat,
                     rowHeight: CGFloat,
                     minSpacing: CGFloat,
                     maxSpacing: CGFloat,
                     noteCount: Int) -> Plan {
        guard noteCount > 0, rowHeight > 0 else { return Plan(rows: 0, spacing: minSpacing) }

        let usable = max(0, availableHeight - headerHeight)
        // Rows that fit when packed at minimum spacing: n*row + (n-1)*min <= usable
        let capacity = Int((usable + minSpacing) / (rowHeight + minSpacing))
        let rows = max(1, min(noteCount, capacity))

        guard rows > 1 else { return Plan(rows: rows, spacing: minSpacing) }

        let slack = usable - CGFloat(rows) * rowHeight
        let even = slack / CGFloat(rows - 1)
        return Plan(rows: rows, spacing: min(max(even, minSpacing), maxSpacing))
    }
}

/// Which prefetched thumbnails fit in the cross-process handoff.
///
/// The snapshot travels through a keychain item, not a file, so image bytes are
/// on a hard diet. Tiles arrive newest-first and are taken in that order; one
/// oversized blob is skipped rather than ending the run, so a single 300 KB
/// screenshot cannot cost you every thumbnail behind it.
enum NVThumbnailBudget {
    static func fit(_ items: [(id: String, byteCount: Int)], budget: Int) -> [String] {
        var remaining = budget
        var kept: [String] = []
        for item in items {
            guard item.byteCount > 0, item.byteCount <= remaining else { continue }
            kept.append(item.id)
            remaining -= item.byteCount
        }
        return kept
    }
}

// MARK: - Media kinds and filtering

/// What a Mosaic tile is. Deliberately coarser than the app's own media types:
/// the widget filter offers the four buckets the Media tab's filter row offers,
/// and nothing the tile grid cannot act on.
enum NVMediaKind: String, Codable, Equatable {
    case image, video, gif, other
}

/// The filter chips across the top of Mosaic, mirroring the Media tab.
enum NVMediaFilter: String, Codable, CaseIterable, Equatable {
    case all, photo, video, gif

    var label: String {
        switch self {
        case .all: return "All"
        case .photo: return "Photos"
        case .video: return "Video"
        case .gif: return "GIF"
        }
    }

    /// A tile from an older snapshot has no kind at all. It is shown under
    /// "All" and hidden by every narrower chip: guessing it is a photo would
    /// put videos in the photo filter, which is worse than an empty chip that
    /// fills in on the next refresh.
    func accepts(_ kind: NVMediaKind?) -> Bool {
        switch self {
        case .all: return true
        case .photo: return kind == .image
        case .video: return kind == .video
        case .gif: return kind == .gif
        }
    }
}
