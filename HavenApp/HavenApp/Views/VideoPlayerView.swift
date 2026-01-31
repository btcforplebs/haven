import SwiftUI
import AVKit
import AVFoundation

struct VideoPlayerView: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var loadError: String? = nil
    
    @State private var viewSize: CGSize = .zero
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let _ = loadError {
                    // ... error view ...
                    errorContent
                } else if let player = player {
                    VideoPlayer(player: player)
                        .onAppear {
                            player.play()
                        }
                        .onDisappear {
                            player.pause()
                        }
                } else {
                    loadingContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minWidth: 300, minHeight: 200) // Avoid AVPlayerView constraint warnings
            .onChange(of: geo.size) { oldValue, newSize in
                // Strict size gate: Don't load player unless we have enough width for the controls
                if viewSize == .zero && newSize.width > 300 {
                    viewSize = newSize
                    setupPlayer()
                }
            }
            .onAppear {
                if geo.size.width > 300 {
                    viewSize = geo.size
                    setupPlayer()
                }
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
    
    private var errorContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            Text("Failed to load video")
                .font(.headline)
            Text(loadError ?? "Unknown error")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button("Try Again") {
                loadError = nil
                setupPlayer()
            }
            .buttonStyle(.bordered)
        }
    }
    
    private var loadingContent: some View {
        VStack(spacing: 20) {
            ProgressView()
            Text("Loading video...")
                .foregroundColor(.secondary)
        }
    }
    
    private func setupPlayer() {
        Task {
            await setupPlayerAsync()
        }
    }
    
    private func setupPlayerAsync() async {
        // 1. Check if we already have a local/cached version
        var playableURL = MediaCacheService.shared.preparePlayableURL(for: url)
        print("VideoPlayerView: Original URL: \(url.absoluteString)")
        print("VideoPlayerView: Initial playableURL: \(playableURL?.absoluteString ?? "nil")")
        print("VideoPlayerView: Source type: \(MediaCacheService.shared.getSource(for: url).rawValue)")
        
        // 2. If not cached and it's a remote URL, download it first
        if playableURL == nil && !MediaCacheService.shared.getSource(for: url).isLocal {
            print("VideoPlayerView: Downloading external video from \(url.absoluteString)")
            
            guard let data = await MediaCacheService.shared.fetchData(url: url) else {
                await MainActor.run {
                    print("VideoPlayerView: Failed to download video from \(url.absoluteString)")
                    self.loadError = "Failed to download video."
                }
                return
            }
            
            print("VideoPlayerView: Downloaded \(data.count) bytes")
            
            // After download, try to get the playable URL again
            playableURL = MediaCacheService.shared.preparePlayableURL(for: url)
            print("VideoPlayerView: Post-download playableURL: \(playableURL?.absoluteString ?? "nil")")
        }
        
        // 3. Use playable URL if available, otherwise fall back to original
        let finalURL = playableURL ?? url
        print("VideoPlayerView: Final URL for playback: \(finalURL.absoluteString)")
        
        // Safety check for local files
        if finalURL.isFileURL {
            // Start by checking the file at the path (resolving symlinks if needed)
            let actualPath = finalURL.resolvingSymlinksInPath().path
            
            if !FileManager.default.fileExists(atPath: actualPath) {
                await MainActor.run {
                    print("VideoPlayerView: Local file missing at \(actualPath)")
                    self.loadError = "Local file not found."
                }
                return
            }
            
            if let attr = try? FileManager.default.attributesOfItem(atPath: actualPath),
               let size = attr[.size] as? UInt64, size < 200 {
                await MainActor.run {
                    print("VideoPlayerView: File too small (\(size) bytes)")
                    self.loadError = "Video file is invalid or too small."
                }
                return
            }
        }
        
        let asset = AVURLAsset(url: finalURL)
        let playerItem = AVPlayerItem(asset: asset)
        
        await MainActor.run {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let newPlayer = AVPlayer(playerItem: playerItem)
                self.player = newPlayer
                
                // Watch for failures
                NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: playerItem,
                    queue: .main
                ) { _ in }
            }
        }
    }
}
