import Foundation

// MARK: - Media Gallery type definitions
// Extracted from ViewerView for the MediaGallery tab split.

enum MediaLayoutMode: String {
    case grid
    case list
}

enum MediaSourceFilter {
    case all
    case blossom
    case cache
}

enum MediaLocationFilter {
    case all
    case blossom
    case cache
    case notFound
}

enum MediaTypeFilter: String, CaseIterable {
    case photo = "Photo"
    case video = "Video"
    case gif = "GIF"
    case other = "Other"
}

// MARK: - Sorting

/// How the media gallery orders its items. Persisted by raw value.
enum MediaSortOption: String, CaseIterable, Identifiable {
    case newestFirst
    case oldestFirst
    case mediaType
    case onRelayFirst

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newestFirst:  return "Newest first"
        case .oldestFirst:  return "Oldest first"
        case .mediaType:    return "Media type"
        case .onRelayFirst: return "On relay first"
        }
    }

    var icon: String {
        switch self {
        case .newestFirst:  return "arrow.down"
        case .oldestFirst:  return "arrow.up"
        case .mediaType:    return "square.grid.3x3"
        case .onRelayFirst: return "externaldrive"
        }
    }

    /// Date headings only mean something when the list is actually ordered by
    /// date. Under any other sort the items are interleaved across dates, so a
    /// "Today" heading would sit above items from any month.
    var groupsByDate: Bool {
        self == .newestFirst || self == .oldestFirst
    }
}

// MARK: - Date sections

/// One dated run of media items, in the order they already appear in the list.
struct MediaDateSection: Identifiable {
    let id: String
    let title: String
    let items: [MediaItem]
}

extension MediaDateSection {
    /// Adapts the generic grouping in `MediaDateGrouping` to the gallery's
    /// items. The heading doubles as the identity: a date-sorted list cannot
    /// produce the same heading twice.
    static func sections(for items: [MediaItem],
                         now: Date = Date(),
                         calendar: Calendar = .current) -> [MediaDateSection] {
        MediaDateGrouping.runs(of: items, date: \.dateAdded, now: now, calendar: calendar)
            .map { MediaDateSection(id: $0.title, title: $0.title, items: $0.items) }
    }
}
