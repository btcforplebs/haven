import SwiftUI
import UniformTypeIdentifiers

// This screen is an iOS-only media gallery: it uses UIKit types (UIImage,
// UIColor, navigationBarTitleDisplayMode) and has no macOS call sites, yet the
// file is a member of BOTH app targets — so without this guard it breaks the
// macOS build ("cannot find type 'UIImage'"). Compile it for iOS only; the
// macOS Blossom UI lives in BlossomDashboardView. If this is ever needed on
// macOS, port it to PlatformImage / Color.platform* rather than dropping the guard.
#if os(iOS)

// MARK: - BlossomMediaListView

/// Visual media gallery showing local Blossom content with easy mirror management.
/// Displays actual photos/videos with thumbnails and simple push/pull operations.
struct BlossomMediaListView: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService

    @State private var mediaItems: [BlossomMediaItem] = []
    @State private var isLoading = true
    @State private var selectedFilter: FilterType = .all
    @State private var isPullingFromNotes = false
    @State private var isPushingAll = false
    @State private var syncProgress: (current: Int, total: Int) = (0, 0)
    @State private var syncMessage: String = ""

    enum FilterType: String, CaseIterable {
        case all = "All"
        case needsBackup = "Needs Backup"
        case backed = "Backed Up"

        var icon: String {
            switch self {
            case .all: return "photo.on.rectangle"
            case .needsBackup: return "arrow.up.circle"
            case .backed: return "checkmark.circle.fill"
            }
        }
    }

    var filteredItems: [BlossomMediaItem] {
        switch selectedFilter {
        case .all:
            return mediaItems
        case .needsBackup:
            return mediaItems.filter { $0.mirrorCount == 0 }
        case .backed:
            return mediaItems.filter { $0.mirrorCount > 0 }
        }
    }

    var needsBackupCount: Int {
        mediaItems.filter { $0.mirrorCount == 0 }.count
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Quick Actions Bar
                if !isLoading && !mediaItems.isEmpty {
                    HStack(spacing: 12) {
                        // Pull from Notes button
                        Button(action: pullFromNotes) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("Pull from Notes")
                                    .fontWeight(.semibold)
                            }
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.blue)
                            .cornerRadius(10)
                        }
                        .disabled(isPullingFromNotes)

                        if needsBackupCount > 0 {
                            // Push All button
                            Button(action: pushAllToMirrors) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up.circle.fill")
                                    Text("Backup All (\(needsBackupCount))")
                                        .fontWeight(.semibold)
                                }
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Color.green)
                                .cornerRadius(10)
                            }
                            .disabled(isPushingAll)
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                }

                // Filter Tabs
                if !isLoading && !mediaItems.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(FilterType.allCases, id: \.self) { filter in
                                FilterChip(
                                    icon: filter.icon,
                                    title: filter.rawValue,
                                    count: countForFilter(filter),
                                    isSelected: selectedFilter == filter
                                ) {
                                    withAnimation {
                                        selectedFilter = filter
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                    }
                    .background(Color(UIColor.systemBackground))

                    Divider()
                }

                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Loading your media...")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if mediaItems.isEmpty {
                    ContentUnavailableView(
                        "No Media Yet",
                        systemImage: "photo.on.rectangle",
                        description: Text("Upload media to your Blossom server or pull from notes to get started")
                    )
                } else if filteredItems.isEmpty {
                    ContentUnavailableView(
                        "No Items",
                        systemImage: "photo.badge.checkmark",
                        description: Text("All media is already backed up!")
                    )
                } else {
                    // Media Grid
                    ScrollView {
                        LazyVGrid(columns: [
                            GridItem(.adaptive(minimum: 160), spacing: 12)
                        ], spacing: 12) {
                            ForEach(filteredItems) { item in
                                BlossomMediaCard(item: item)
                                    .environmentObject(configService)
                                    .environmentObject(nostrService)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Blossom Media")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: refreshList) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .sheet(isPresented: $isPullingFromNotes) {
                SyncProgressSheet(
                    title: "Pulling from Notes",
                    message: syncMessage,
                    current: syncProgress.current,
                    total: syncProgress.total
                )
            }
            .sheet(isPresented: $isPushingAll) {
                SyncProgressSheet(
                    title: "Backing Up to Mirrors",
                    message: syncMessage,
                    current: syncProgress.current,
                    total: syncProgress.total
                )
            }
        }
        .task {
            await loadMediaItems()
        }
    }

    private func countForFilter(_ filter: FilterType) -> Int {
        switch filter {
        case .all:
            return mediaItems.count
        case .needsBackup:
            return mediaItems.filter { $0.mirrorCount == 0 }.count
        case .backed:
            return mediaItems.filter { $0.mirrorCount > 0 }.count
        }
    }

    private func loadMediaItems() async {
        isLoading = true

        let relayDataDir = await MainActor.run { configService.relayDataDir }
        let blossomPath = await MainActor.run { configService.config.blossomPath }
        let mirrors = await MainActor.run { configService.config.activeBlossomMirrors }
        let blossomDir = relayDataDir.appendingPathComponent(blossomPath)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: blossomDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            await MainActor.run {
                isLoading = false
            }
            return
        }

        // Filter to valid hash files (64 hex chars, optionally with extension)
        let validFiles = files.filter { url in
            let hashPart = url.deletingPathExtension().lastPathComponent
            return hashPart.count == 64 && hashPart.allSatisfy { $0.isHexDigit }
        }

        let service = BlossomService(configService: configService, nostrService: nostrService)

        var items: [BlossomMediaItem] = []

        for fileURL in validFiles {
            let hash = fileURL.deletingPathExtension().lastPathComponent

            // Get file metadata
            let attrs = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = attrs?.fileSize ?? 0
            let modDate = attrs?.contentModificationDate ?? Date()

            // Determine media type from extension or file
            let mediaType = inferMediaType(from: fileURL)

            // Check mirror status
            let mirrorStatus = await service.checkMirrorStatus(sha256: hash)
            let mirrorCount = mirrorStatus.values.filter { $0 }.count

            let item = BlossomMediaItem(
                hash: hash,
                fileName: fileURL.lastPathComponent,
                fileURL: fileURL,
                sizeBytes: size,
                modifiedDate: modDate,
                mediaType: mediaType,
                mirrorStatus: mirrorStatus,
                mirrorCount: mirrorCount,
                totalMirrors: mirrors.count
            )

            items.append(item)
        }

        await MainActor.run {
            mediaItems = items.sorted { $0.modifiedDate > $1.modifiedDate }
            isLoading = false
        }
    }

    private func inferMediaType(from url: URL) -> BlossomMediaType {
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(ext) {
            return .image
        } else if ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(ext) {
            return .video
        } else if ["mp3", "m4a", "wav", "aac", "flac"].contains(ext) {
            return .audio
        }
        return .other
    }

    private func refreshList() {
        Task {
            await loadMediaItems()
        }
    }

    private func pullFromNotes() {
        Task {
            await MainActor.run {
                isPullingFromNotes = true
                syncProgress = (0, 0)
                syncMessage = "Scanning notes for media..."
            }

            let service = BlossomService(configService: configService, nostrService: nostrService)
            let noteMedia = await MainActor.run { nostrService.noteMedia }

            await MainActor.run {
                syncProgress = (0, noteMedia.count)
            }

            // Use the mirrorFromNoteMedia function which handles downloading from notes
            _ = await service.mirrorFromNoteMedia(noteMedia) { current, total in
                Task { @MainActor in
                    syncProgress = (current, total)
                    syncMessage = "Downloading \(current) of \(total)..."
                }
            } logMessage: { message, level in
                Task { @MainActor in
                    syncMessage = message
                }
            }

            // Refresh the list after pulling
            await loadMediaItems()

            await MainActor.run {
                isPullingFromNotes = false
            }
        }
    }

    private func pushAllToMirrors() {
        Task {
            let unmirroredItems = mediaItems.filter { $0.mirrorCount == 0 }
            guard !unmirroredItems.isEmpty else { return }

            await MainActor.run {
                isPushingAll = true
                syncProgress = (0, unmirroredItems.count)
                syncMessage = "Starting backup..."
            }

            let service = BlossomService(configService: configService, nostrService: nostrService)

            for (index, item) in unmirroredItems.enumerated() {
                await MainActor.run {
                    syncMessage = "Backing up \(item.fileName.prefix(20))..."
                    syncProgress = (index, unmirroredItems.count)
                }

                _ = await service.pushLocalToMirrors(sha256: item.hash)

                await MainActor.run {
                    syncProgress = (index + 1, unmirroredItems.count)
                }
            }

            // Refresh list after pushing
            await loadMediaItems()

            await MainActor.run {
                isPushingAll = false
            }
        }
    }
}

// MARK: - BlossomMediaType

enum BlossomMediaType {
    case image
    case video
    case audio
    case other

    var icon: String {
        switch self {
        case .image: return "photo.fill"
        case .video: return "video.fill"
        case .audio: return "waveform"
        case .other: return "doc.fill"
        }
    }
}

// MARK: - BlossomMediaItem

struct BlossomMediaItem: Identifiable {
    let id = UUID()
    let hash: String
    let fileName: String
    let fileURL: URL
    let sizeBytes: Int
    let modifiedDate: Date
    let mediaType: BlossomMediaType
    let mirrorStatus: [String: Bool]
    let mirrorCount: Int
    let totalMirrors: Int

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }

    var statusColor: Color {
        if mirrorCount == 0 {
            return .orange
        } else if mirrorCount == totalMirrors {
            return .green
        } else {
            return .blue
        }
    }

    var statusText: String {
        if totalMirrors == 0 {
            return "No mirrors"
        } else if mirrorCount == 0 {
            return "Not backed up"
        } else if mirrorCount == totalMirrors {
            return "Backed up"
        } else {
            return "\(mirrorCount)/\(totalMirrors) mirrors"
        }
    }
}

// MARK: - BlossomMediaCard

struct BlossomMediaCard: View {
    let item: BlossomMediaItem
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @State private var thumbnail: UIImage?
    @State private var showMirrorStatus = false
    @State private var isPushing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thumbnail
            ZStack {
                if let thumbnail = thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 160)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color(UIColor.secondarySystemBackground))
                        .frame(height: 160)
                        .overlay {
                            Image(systemName: item.mediaType.icon)
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                        }
                }

                // Status badge overlay
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: item.mirrorCount == 0 ? "arrow.up.circle.fill" : "checkmark.circle.fill")
                                .font(.system(size: 10))
                            Text("\(item.mirrorCount)")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(item.statusColor)
                        .cornerRadius(12)
                        .padding(8)
                    }
                    Spacer()
                }
            }
            .frame(height: 160)
            .cornerRadius(12)

            // Info section
            VStack(alignment: .leading, spacing: 4) {
                Text(item.formattedSize)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Text(item.statusText)
                    .font(.caption)
                    .foregroundColor(item.statusColor)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            // Action buttons
            HStack(spacing: 6) {
                Button(action: { showMirrorStatus = true }) {
                    Label("Info", systemImage: "info.circle")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if item.mirrorCount < item.totalMirrors && item.totalMirrors > 0 {
                    Button(action: pushToMirrors) {
                        if isPushing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Backup", systemImage: "arrow.up.circle")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isPushing)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(Color(UIColor.tertiarySystemBackground))
        .cornerRadius(12)
        .task {
            await loadThumbnail()
        }
        .sheet(isPresented: $showMirrorStatus) {
            MirrorStatusSheet(url: item.fileURL)
                .environmentObject(configService)
                .environmentObject(nostrService)
        }
    }

    private func loadThumbnail() async {
        guard item.mediaType == .image || item.mediaType == .video else { return }

        if item.mediaType == .image {
            if let image = UIImage(contentsOfFile: item.fileURL.path) {
                await MainActor.run {
                    thumbnail = image
                }
            }
        } else if item.mediaType == .video {
            let thumb = await MediaCacheService.shared.generateThumbnail(for: item.fileURL)
            await MainActor.run {
                thumbnail = thumb
            }
        }
    }

    private func pushToMirrors() {
        isPushing = true
        Task {
            let service = BlossomService(configService: configService, nostrService: nostrService)
            _ = await service.pushLocalToMirrors(sha256: item.hash)

            await MainActor.run {
                isPushing = false
            }
        }
    }
}

// MARK: - FilterChip

struct FilterChip: View {
    let icon: String
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))

                Text(title)
                    .font(.system(size: 13, weight: .medium))

                Text("(\(count))")
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.blue : Color(UIColor.secondarySystemBackground))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(20)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SyncProgressSheet

struct SyncProgressSheet: View {
    let title: String
    let message: String
    let current: Int
    let total: Int

    var progress: Double {
        guard total > 0 else { return 0 }
        return Double(current) / Double(total)
    }

    var body: some View {
        VStack(spacing: 20) {
            ProgressView(value: progress) {
                Text(title)
                    .font(.headline)
            } currentValueLabel: {
                Text("\(current) of \(total)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding()
        .frame(maxWidth: 300)
        .presentationDetents([.height(200)])
    }
}

#endif // os(iOS)
