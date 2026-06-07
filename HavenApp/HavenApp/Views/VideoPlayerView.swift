import SwiftUI
import AVKit
import AVFoundation

#if os(iOS)
import UIKit
#endif

// MARK: - Audio Session Manager

/// Manages audio session configuration for video playback.
/// Switches between ambient (mixing with background music) and playback (taking over audio) modes.
class AudioSessionManager {
    static let shared = AudioSessionManager()

    #if os(iOS)
    /// Configure audio session to allow background music to continue (for muted videos)
    func enableMixingWithOthers() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // Deactivate the active playback session so background music can resume
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)

            // Set category to ambient with mixing - don't activate yet, let AVPlayer handle it
            try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            #if DEBUG
            print("AudioSession: Configured for ambient playback (mixing with background music)")
            #endif
        } catch {
            #if DEBUG
            print("AudioSession: Failed to enable mixing: \(error)")
            #endif
        }
    }

    /// Configure audio session to take over audio (for unmuted full-screen videos)
    func enablePlayback() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // Deactivate current session first to ensure clean transition
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)

            // Use .playback category which ignores the hardware mute switch
            // Use .moviePlayback mode for optimal video playback
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [])
            try audioSession.setActive(true)
            #if DEBUG
            print("AudioSession: Configured for playback (taking over audio, ignoring mute switch)")
            #endif
        } catch {
            #if DEBUG
            print("AudioSession: Failed to enable playback: \(error)")
            #endif
        }
    }
    #else
    // macOS doesn't need audio session management
    func enableMixingWithOthers() {}
    func enablePlayback() {}
    #endif
}

// MARK: - VideoPlayerCache

class VideoPlayerCache: ObservableObject {
    static let shared = VideoPlayerCache()
    private var cache: [URL: AVPlayer] = [:]
    private var observers: [URL: NSObjectProtocol] = [:]
    private var accessOrder: [URL] = []
    private let limit = 3
    private let lock = NSLock()

    /// Tracks which video URL is currently being viewed full-screen so we don't pause it when the feed cell goes off-screen
    @Published var activeFullScreenURL: URL? = nil

    /// Evicts all cached players (called on memory pressure).
    func evictAll() {
        lock.lock()
        defer { lock.unlock() }
        for (_, player) in cache {
            player.pause()
        }
        for (_, obs) in observers {
            NotificationCenter.default.removeObserver(obs)
        }
        cache.removeAll()
        observers.removeAll()
        accessOrder.removeAll()
    }

    func player(for url: URL) -> AVPlayer {
        lock.lock()
        defer { lock.unlock() }

        // Update LRU access order
        if let index = accessOrder.firstIndex(of: url) {
            accessOrder.remove(at: index)
        }
        accessOrder.append(url)

        if let existing = cache[url] {
            // Evict broken players so they get recreated with (potentially now-correct) MIME info
            if existing.currentItem?.status != .failed && existing.currentItem?.error == nil {
                return existing
            }
            #if DEBUG
            print("VideoPlayerCache: Evicting failed player for \(url.lastPathComponent)")
            #endif
            existing.pause()
            if let obs = observers.removeValue(forKey: url) {
                NotificationCenter.default.removeObserver(obs)
            }
            cache.removeValue(forKey: url)
        }

        let finalURL = MediaCacheService.shared.preparePlayableURL(for: url) ?? url

        var assetOptions: [String: Any] = [:]
        if finalURL.pathExtension.isEmpty {
            let mimeType = MediaTypeDetector.shared.getCachedContentType(for: url) ?? "video/mp4"
            assetOptions[AVURLAssetOverrideMIMETypeKey] = mimeType
        }

        let asset = AVURLAsset(url: finalURL, options: assetOptions)
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        player.isMuted = true

        // Configure audio session to mix with background music since player starts muted
        AudioSessionManager.shared.enableMixingWithOthers()

        // Auto-looping logic
        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }

        cache[url] = player
        observers[url] = observer

        // Evict oldest if limit exceeded
        if cache.count > limit {
            if let oldest = accessOrder.first {
                accessOrder.removeFirst()
                if let oldPlayer = cache.removeValue(forKey: oldest) {
                    oldPlayer.pause()
                }
                if let oldObserver = observers.removeValue(forKey: oldest) {
                    NotificationCenter.default.removeObserver(oldObserver)
                }
            }
        }

        return player
    }
}

struct VideoPlayerView: View {
    let url: URL
    /// Optional MIME hint used when the URL has no extension (e.g. Blossom hashes).
    /// AVFoundation can't infer the container format without it, so playback fails silently.
    var mimeType: String? = nil
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
                    NativeVideoPlayer(player: player)
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
            .onChange(of: geo.size) { _, newSize in
                // Strict size gate: Don't load player unless we have enough width for the controls
                if viewSize == .zero && newSize.width > 100 && newSize.height > 100 {
                    viewSize = newSize
                    setupPlayer()
                }
            }
            .onAppear {
                if geo.size.width > 100 && geo.size.height > 100 {
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
                .font(.appSystem(size: 40))
                .foregroundColor(.orange)
            Text("Failed to load video")
                .font(.appHeadline)
            Text(loadError ?? "Unknown error")
                .font(.appCaption)
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
            // For extensionless remote URLs (e.g. Blossom hashes), detect content type first
            var detectedMIME: String? = mimeType
            if url.pathExtension.isEmpty && !url.isFileURL {
                detectedMIME = await MediaTypeDetector.shared.detectContentTypeAsync(for: url) ?? mimeType
                #if DEBUG
                if let detected = detectedMIME {
                    print("VideoPlayerView: Detected MIME type '\(detected)' for \(url.lastPathComponent)")
                } else {
                    print("VideoPlayerView: Failed to detect MIME type for \(url.lastPathComponent), will use fallback")
                }
                #endif
            }

            await MainActor.run {
                setupPlayerWithMIME(detectedMIME)
            }
        }
    }

    private func setupPlayerWithMIME(_ detectedMIME: String?) {
        // Use the new helper to get a guaranteed playable URL (with extension)
        let finalURL = MediaCacheService.shared.preparePlayableURL(for: url, extensionHint: detectedMIME) ?? url

        // Safety check for local files
        if finalURL.isFileURL {
            // Start by checking the file at the path (resolving symlinks if needed)
            let actualPath = finalURL.resolvingSymlinksInPath().path

            if !FileManager.default.fileExists(atPath: actualPath) {
                #if DEBUG
                print("VideoPlayerView: Local file missing at \(actualPath)")
                #endif
                loadError = "Local file not found."
                return
            }

            if let attr = try? FileManager.default.attributesOfItem(atPath: actualPath),
               let size = attr[.size] as? UInt64, size < 200 {
                #if DEBUG
                print("VideoPlayerView: File too small (\(size) bytes)")
                #endif
                loadError = "Video file is invalid or too small."
                return
            }
        }

        // Strict Constraint Safety:
        // AVPlayerViewController (AppKit backend) throws constraint exceptions if initialized
        // with near-zero frames. We must ensure we are ready.
        if viewSize.width < 100 || viewSize.height < 100 {
            #if DEBUG
            print("VideoPlayerView: Skipping setup - view too small (\(viewSize))")
            #endif
            return
        }

        #if DEBUG
        print("VideoPlayerView: Setting up player for \(finalURL.lastPathComponent)")
        #endif

        // For extensionless remote URLs (e.g. Blossom hashes), AVFoundation can't infer the
        // content type from the URL alone. We must provide an explicit MIME type hint via
        // AVURLAssetOverrideMIMETypeKey so AVPlayer knows how to demux the stream.
        var assetOptions: [String: Any] = [:]
        if finalURL.pathExtension.isEmpty {
            // Prefer detected MIME, then caller-supplied mime, then the detector cache, fall back to video/mp4
            let resolved = detectedMIME
                ?? mimeType
                ?? MediaTypeDetector.shared.getCachedContentType(for: url)
                ?? "video/mp4"
            assetOptions[AVURLAssetOverrideMIMETypeKey] = resolved
            #if DEBUG
            print("VideoPlayerView: Using MIME override '\(resolved)' for extensionless URL")
            #endif
        }

        let asset = AVURLAsset(url: finalURL, options: assetOptions)
        let playerItem = AVPlayerItem(asset: asset)

        // Initialize immediately - removing the async delay which caused race conditions
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

// MARK: - VideoScrubber

/// Minimal seek bar — thin progress line with drag-to-seek.
struct VideoScrubber: View {
    let player: AVPlayer

    @State private var progress: Double = 0
    @State private var isDragging: Bool = false
    @State private var timeObserver: Any?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(height: 3)

                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: max(0, geo.size.width * progress), height: isDragging ? 5 : 3)
                    .animation(.easeOut(duration: 0.15), value: isDragging)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        progress = fraction
                        seek(to: fraction)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: 20) // generous hit target
        .onAppear { startObserving() }
        .onDisappear { stopObserving() }
    }

    private func startObserving() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            guard !isDragging else { return }
            guard let duration = player.currentItem?.duration,
                  duration.isValid, !duration.isIndefinite else { return }
            let total = CMTimeGetSeconds(duration)
            guard total > 0 else { return }
            progress = CMTimeGetSeconds(time) / total
        }
    }

    private func stopObserving() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    private func seek(to fraction: Double) {
        guard let duration = player.currentItem?.duration,
              duration.isValid, !duration.isIndefinite else { return }
        let target = CMTimeGetSeconds(duration) * fraction
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

// MARK: - VideoShimmerPlaceholder

/// Animated shimmer placeholder shown while a video thumbnail is loading.
/// Provides visual feedback that content is incoming rather than a blank grey frame.
private struct VideoShimmerPlaceholder: View {
    @State private var phase: CGFloat = -1.0

    var body: some View {
        ZStack {
            Color.platformTertiaryGroupedBackground

            // Subtle gradient shimmer sweep
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0), location: max(0, phase - 0.3)),
                    .init(color: .white.opacity(0.06), location: phase),
                    .init(color: .white.opacity(0), location: min(1, phase + 0.3))
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Centered video icon so user knows this is a video
            Image(systemName: "video.fill")
                .font(.appSystem(size: 24))
                .foregroundColor(.white.opacity(0.25))
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 2.0
            }
        }
    }
}

// MARK: - InlineFeedVideoPlayer

/// Lightweight inline video player for feed cards.
/// - Auto-plays muted when visible
/// - Loops continuously
/// - Tap toggles mute (shows speaker icon briefly)
/// - Pauses when scrolled off-screen
struct InlineFeedVideoPlayer: View {
    let url: URL
    /// Called when the user taps the video body (excluding the mute button).
    var onTap: (() -> Void)? = nil
    @ObservedObject private var cache = VideoPlayerCache.shared
    @State private var player: AVPlayer?
    @State private var isMuted: Bool = true
    @State private var isPlaying: Bool = false
    @State private var loadError: String? = nil
    @State private var thumbnail: PlatformImage? = nil
    @State private var loopObserver: NSObjectProtocol? = nil
    @State private var isReadyToPlay: Bool = false
    @State private var deferredSetup: DispatchWorkItem? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.platformTertiaryGroupedBackground

                if let _ = loadError {
                    // Show thumbnail with play overlay on error
                    if let thumb = thumbnail {
                        Image(platformImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                    Image(systemName: "play.circle.fill")
                        .font(.appSystem(size: 36))
                        .foregroundColor(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.5), radius: 4)
                } else if let player = player {
                    ZStack {
                        if cache.activeFullScreenURL != url {
                            InlinePlayerLayer(player: player)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .allowsHitTesting(false) // Let touches fall through natively for seamless swiping and tapping!
                                .onReceive(player.publisher(for: \.timeControlStatus)) { status in
                                    if status == .playing {
                                        withAnimation(.easeOut(duration: 0.3)) {
                                            isReadyToPlay = true
                                        }
                                    }
                                }
                                .onReceive(player.publisher(for: \.status)) { status in
                                    if status == .readyToPlay {
                                        if player.rate > 0 || CMTimeGetSeconds(player.currentTime()) > 0.1 {
                                            withAnimation(.easeOut(duration: 0.3)) {
                                                isReadyToPlay = true
                                            }
                                        }
                                    }
                                }
                        } else {
                            // Detached for full-screen: render static thumbnail
                            if let thumb = thumbnail {
                                Image(platformImage: thumb)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: geo.size.width, height: geo.size.height)
                            }
                        }

                        // Seamless thumbnail overlay that fades out once player starts rendering
                        if !isReadyToPlay && cache.activeFullScreenURL != url, let thumb = thumbnail {
                            Image(platformImage: thumb)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height)
                                .transition(.opacity)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { onTap?() }
                } else {
                    // Loading — show thumbnail if ready, otherwise shimmer placeholder
                    if let thumb = thumbnail {
                        Image(platformImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                    } else {
                        VideoShimmerPlaceholder()
                    }
                }

                // Bottom controls: mute button + scrubber
                VStack(spacing: 0) {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(action: toggleMute) {
                            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.appSystem(size: 14, weight: .medium))
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Circle().fill(Color.black.opacity(0.6)))
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
                    if let player = player {
                        VideoScrubber(player: player)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 4)
                    }
                }
            }
            .clipped()
            .onAppear {
                if geo.size.width > 50 {
                    if player == nil {
                        loadThumbnail()
                        // Defer player setup by 300ms so fast-scrolling
                        // never triggers AVPlayer creation
                        let work = DispatchWorkItem { [self] in
                            if self.player == nil {
                                self.setupPlayer()
                            }
                        }
                        deferredSetup = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
                    } else {
                        // Ensure audio session is configured for mixing when resuming muted playback
                        if isMuted {
                            AudioSessionManager.shared.enableMixingWithOthers()
                        }
                        player?.play()
                        isPlaying = true
                    }
                }
            }
            .onDisappear {
                deferredSetup?.cancel()
                deferredSetup = nil
                if VideoPlayerCache.shared.activeFullScreenURL != url {
                    player?.pause()
                    isPlaying = false
                    isReadyToPlay = false
                    // Restore mixing mode when video leaves screen (in case it was unmuted)
                    if !isMuted {
                        AudioSessionManager.shared.enableMixingWithOthers()
                        isMuted = true
                    }
                }
            }
        }
    }

    private func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted

        // Update audio session based on mute state
        if isMuted {
            AudioSessionManager.shared.enableMixingWithOthers()
        } else {
            AudioSessionManager.shared.enablePlayback()
        }
    }

    private func loadThumbnail() {
        Task {
            if let thumb = await MediaCacheService.shared.generateThumbnail(for: url) {
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.25)) {
                        self.thumbnail = thumb
                    }
                }
            }
        }
    }

    private func setupPlayer() {
        // For extensionless remote URLs, detect content type first to ensure proper playback
        if url.pathExtension.isEmpty && !url.isFileURL {
            Task {
                _ = await MediaTypeDetector.shared.detectContentTypeAsync(for: url)
                await MainActor.run {
                    initializePlayer()
                }
            }
        } else {
            initializePlayer()
        }
    }

    private func initializePlayer() {
        // Configure audio session before initializing player
        // Since videos start muted by default, enable mixing with background music
        if isMuted {
            AudioSessionManager.shared.enableMixingWithOthers()
        }

        let cachedPlayer = VideoPlayerCache.shared.player(for: url)
        cachedPlayer.isMuted = isMuted
        self.player = cachedPlayer
        cachedPlayer.play()
        isPlaying = true
    }
}

// MARK: - InlinePlayerLayer (chromeless AVPlayerLayer)

#if os(macOS)
struct InlinePlayerLayer: NSViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        return view
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        if nsView.playerLayer.player != player {
            nsView.playerLayer.player = player
        }
        if nsView.playerLayer.videoGravity != videoGravity {
            nsView.playerLayer.videoGravity = videoGravity
        }
    }
    
    static func dismantleNSView(_ nsView: PlayerNSView, coordinator: Coordinator) {
        nsView.playerLayer.player = nil
    }
}

class PlayerNSView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.isOpaque = true
    }

    override func makeBackingLayer() -> CALayer {
        let playerLayer = AVPlayerLayer()
        playerLayer.isOpaque = true
        return playerLayer
    }
    
    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
#else
struct InlinePlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        if uiView.playerLayer.player != player {
            uiView.playerLayer.player = player
        }
        if uiView.playerLayer.videoGravity != videoGravity {
            uiView.playerLayer.videoGravity = videoGravity
        }
    }
    
    static func dismantleUIView(_ uiView: PlayerUIView, coordinator: Coordinator) {
        uiView.playerLayer.player = nil
    }

    class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
#endif

// MARK: - Full VideoPlayerView (native controls, used for standalone playback)

#if os(macOS)
struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player != player {
            nsView.player = player
        }
    }
}
#else
struct NativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        if #available(iOS 16.0, *) {
            controller.allowsVideoFrameAnalysis = true
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player != player {
            uiViewController.player = player
        }
    }
}
#endif

// MARK: - FullScreenVideoPlayer

/// Chromeless full-screen video player for use in FeedMediaViewer.
/// Auto-plays unmuted with looping. All overlay controls (mirror, close) are provided by FeedMediaViewer.
struct FullScreenVideoPlayer: View {
    let url: URL
    var mimeType: String? = nil

    @State private var player: AVPlayer?
    @State private var loadError: String? = nil

    var body: some View {
        ZStack {
            Color.black

            if let _ = loadError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.appSystem(size: 40))
                        .foregroundColor(.orange)
                    Text("Failed to load video")
                        .font(.appHeadline)
                        .foregroundColor(.white)
                }
            } else if let player = player {
                InlinePlayerLayer(player: player, videoGravity: .resizeAspect)
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white)
            }

            if let player = player {
                VStack {
                    Spacer()
                    VideoScrubber(player: player)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
            }
        }
        .onAppear {
            VideoPlayerCache.shared.activeFullScreenURL = url
            // Configure audio session to take over playback for unmuted full-screen video
            AudioSessionManager.shared.enablePlayback()
            setupPlayer()
        }
        .onDisappear {
            VideoPlayerCache.shared.activeFullScreenURL = nil
            // Restore standard inline muted play
            player?.isMuted = true
            player = nil
            // Restore audio session to allow mixing with background music
            AudioSessionManager.shared.enableMixingWithOthers()
        }
    }

    private func setupPlayer() {
        // For extensionless remote URLs, detect content type first
        if url.pathExtension.isEmpty && !url.isFileURL {
            Task {
                _ = await MediaTypeDetector.shared.detectContentTypeAsync(for: url)
                await MainActor.run {
                    initializePlayer()
                }
            }
        } else {
            initializePlayer()
        }
    }

    private func initializePlayer() {
        // Ensure audio session is ready for unmuted playback (ignores hardware mute switch)
        AudioSessionManager.shared.enablePlayback()

        let cachedPlayer = VideoPlayerCache.shared.player(for: url)
        cachedPlayer.isMuted = false
        cachedPlayer.volume = 1.0 // Ensure player volume is at maximum
        self.player = cachedPlayer
        cachedPlayer.play()
    }
}
