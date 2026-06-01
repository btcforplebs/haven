import SwiftUI

// MARK: - MediaTabView

/// Standalone media tab that displays relay/blossom media using ViewerView in media-only mode.
struct MediaTabView: View {
    var body: some View {
        ViewerView(mediaOnly: true)
    }
}
