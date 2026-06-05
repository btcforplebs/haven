import SwiftUI

// MARK: - MediaTabView

/// Blossom tab that displays local and mirrored media using ViewerView in media-only mode.
struct MediaTabView: View {
    var body: some View {
        ViewerView(mediaOnly: true)
    }
}
