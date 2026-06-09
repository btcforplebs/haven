import Foundation

// MARK: - Media Gallery type definitions
// Extracted from ViewerView for the MediaGallery tab split.

enum MediaLayoutMode {
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
