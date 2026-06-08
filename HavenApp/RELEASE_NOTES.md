# Haven App v2.5.1 Build 7 (macOS) / v1.1.1 Build 7 (iOS) Release Notes

This update adds Web of Trust media filtering, FIPS overlay network publishing, outbox relay model support, instant cold-launch feed restore, proof of work mining, global search, and dozens of performance and reliability improvements across macOS, iOS, and iPadOS.

## Key Features

*   **WoT Media Filtering**: The Media tab now shows only media from Web of Trust members (plus the owner's own), reducing noise and spam from unknown accounts. Falls back to showing everything if the WoT graph hasn't loaded yet.
*   **FIPS Blossom Publishing (macOS)**: Detects whether nostr-vpn (nvpn) is running and lets users publish their `.fips` Blossom address in their server list (kind 10063). FIPS URL is appended last in the mirror list (clearnet-first per BUD-14).
*   **Instant Cold-Launch Feed Restore**: Feed state is persisted to disk on app background/terminate and restored instantly on next cold launch, eliminating the blank-screen wait.
*   **Proof of Work (NIP-13)**: Optional proof-of-work mining for notes, replies, reactions, reposts, and DMs. Configurable per-category difficulty (8–32 bits) in Settings.
*   **Global Search (NIP-50)**: Search gains a relay/global toggle. Global mode queries public NIP-50 search relays with deduplication and a 4-second collection window.
*   **Profile "Tagged" Tab**: Profile view adds a "Tagged" section listing notes from other users that mention, reply to, or tag the profile.
*   **Outbox Relay Model (NIP-65)**: Write-side relay URLs from kind 10002 events are now parsed and cached, improving relay list discovery and DM relay routing.

## Improvements

*   **Event Publishing Reuses Feed Connection**: Publishes go through the existing feed WebSocket instead of opening a temporary connection per event.
*   **Responsive Toolbar Menus**: Feed toolbars use `ViewThatFits` — filters render inline when space permits, collapsing to an overflow menu on narrow windows.
*   **Video Shimmer Placeholder**: Animated gradient shimmer replaces the generic spinner while video thumbnails load.
*   **Incremental Feed Row-Data Cache**: Profile updates, likes, zaps, and reposts trigger targeted row-level cache updates instead of full rebuilds, reducing frame drops.
*   **Condensed Note View**: Per-feed compact mode with independent toggles per feed tab.
*   **Audio Session Management**: Muted video autoplay no longer interrupts background music; unmuted playback properly takes over audio.
*   **Counterpart DM Relay Inclusion**: DM fetching now includes relays from conversation counterparts for better message discovery.
*   **Account Switch Reconnection**: Switching accounts now properly rebuilds WebSocket connections, fixing the stale relay indicator and empty feed.
*   **Blossom Mirror Detection**: Mirror status checks blob SHA-256 against the local store instead of matching URL hosts.
*   **macOS Keyboard Shortcuts**: Cmd+1–6 for tabs, Cmd+, for Settings, Cmd+N for Compose.
*   **Log Level Filter**: Filter logs by severity (All/Info+/Warn+/Errors) in the Logs view.

## Bug Fixes

*   **Thread-Safe Event Deduplication**: `seenEventIds` guarded by `NSLock`, eliminating EXC_BAD_ACCESS crashes from concurrent Set mutations.
*   **"Loading Notes…" Stuck Forever**: Fetch count now tracks only actually-opened subscriptions; 8-second watchdog force-clears stale fetches.
*   **NIP-42 AUTH Signing**: DM NIP-42 AUTH now always uses the local relay's owner key.
*   **Max Reconnect Slot Leak**: Dead relays release their slot from `activeSubscriptionCount`.
*   **Go Relay File Descriptor Leak**: `initRelays` now defers `file.Close()` after copying downloaded data.
*   **Relay List Fetch Broadened**: Queries both kind 10002 and 10050 in a single subscription; re-fetches when DM relay data is missing.
*   **Profile Update Persistence**: In-place profile edits now persist immediately instead of waiting for the next periodic save.

## Removed

*   Relay Note Search Bar (superseded by Global Search)
*   Dashboard Compact Stats Toggle
*   Apple Sign In Identity Backup (experimental, never released)
*   Lightning Balance in Profile
