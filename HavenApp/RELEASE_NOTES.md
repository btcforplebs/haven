# Haven Release 2.2.0

> [!IMPORTANT]
> **Installation Note**: Haven is currently unsigned code. macOS will likely block the application from opening by default. To bypass this, simply **Right-Click (or Control-Click)** the app and select **Open**. You may need to do this twice.

## 🎥 Video Playback Framework Overhaul
We've completely rewritten how the app interacts with local media to handle "extensionless" files (common in Nostr/Blossom storage) that previously failed to play.

- **Local Video Playback**: Fixed an issue where locally synced videos would fail to load. The app now uses a smart symlinking strategy to ensure `AVFoundation` correctly recognizes video formats.
- **"File Too Small" Errors**: Resolved a bug where video size checks were inspecting the symlink instead of the actual file, preventing playback of valid videos.
- **Thumbnail Generation**: Videos now generate accurate thumbnails instantly, even for extensionless files. Added a 200ms "settle" delay and retry logic to prevent `FFR_Common` error -12847 which occurred when AVFoundation attempted to decode video files before they were fully flushed to disk.

## 🖼️ Media Viewer & Layout
- **Correct Sorting**: Media items in the viewer are now strictly sorted by the Nostr event timestamp (newest first). This fixes issues where syncing would scramble the order based on file download time.
- **Layout Stability**: Resolved aggressive layout constraint warnings in the video player controls. The player now intelligently waits for sufficient screen space before initializing, preventing UI "crunch" errors during view transitions.
- **Visual Polish**: Enforced minimum frame sizes for the video player overlay to ensure controls are always accessible.
- **Media Caching**: Implemented locking mechanisms to prevent race conditions and ensure only one download task runs per unique file hash. Fixed deduplication for different URLs pointing to the same file.

## 🌩️ Backend & Networking (Web of Trust)
Significant refactoring of the internal Go backend to improve performance and code organization, incorporating major improvements from upstream ([bitvora/haven](https://github.com/bitvora/haven)).

- **WOT Refactor**: Extracted the Web of Trust (WoT) functionality into its own dedicated package (`haven-go/wot`).
- **New Features**:
    - **Lockless Refresh**: Implemented lockless WoT refresh for better concurrency (see [PR #108](https://github.com/bitvora/haven/pull/108)).
    - **Initialization Fixes**: Corrected startup initialization order to prevent race conditions (see [PR #112](https://github.com/bitvora/haven/pull/112)).
    - **Owner Public Key Config**: Added owner public key to relay configuration.
- **Code Quality**: General cleanup, including switching to `slog` and set-based optimization (see [PR #113](https://github.com/bitvora/haven/pull/113)).

## 🚀 Performance & Startup Optimization
- **Dashboard Stats**: Consolidated stats refresh triggers to separate local disk size updates from remote counts, eliminating redundant network fetches at launch.
- **WebSocket Improvements**:
    - Added `User-Agent: Haven/1.0` header to resolve connection handshake issues with specific relays (e.g., nostr.wine).
    - Implemented `isClosing` flag to suppress noisy error logs during intentional disconnects.
    - Added `isTemporary` flag to reduce log noise for one-off utility connections.
- **Batched Metadata Fetching**: Implemented 500ms batched metadata fetching with deduplication to prevent redundant relay connections for profile data.
- **Stats Service Refactor**: Refactored into a singleton pattern with re-entrancy protection for more reliable stats updates.

## 🔒 Security
- **App Transport Security**: Added `Info.plist` with proper App Transport Security settings for network requests.

## 📦 Maintenance
- **Version Bump**: 2.2.0
- **Dependencies**: Updated various Go dependencies to their latest safe versions.
- **CI/CD**: Streamlined release artifact generation.

---

Thank you for using Haven!
