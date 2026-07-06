# Haven App v2.6.0 Build 11 (macOS) / v1.2.0 Build 11 (iOS) Release Notes

This update removes the remote push server entirely — notifications are now generated fully on-device from your own relay — adds Picture-in-Picture video on iOS and Android, and fixes a Web of Trust bug that was causing real replies and reactions to go silently missing.

## Key Features

*   **No More Push Server**: Every notification — mentions, replies, DMs, zaps, reactions, reposts — is now generated entirely on-device from your own embedded relay. Nothing about who's contacting you, or when, ever passes through a third-party server — not Apple's, not Google's, not ours.
*   **Picture-in-Picture Video**: Full-screen video now supports PiP on both iOS and Android — swipe home or tap the PiP button and it keeps playing in a floating window. A new unified control rail (play/pause, time, scrubber, mute, PiP) auto-hides while playing.
*   **Catch-Up Summary Notifications**: Coming back to the app after being away now shows one clean "N new notifications" summary instead of a flood of individual pushes.

## Improvements

*   **Per-Account Notification Accuracy**: On multi-account setups, notifications now apply the correct account's preferences and open the correct account, instead of guessing from whichever one is currently active.
*   **Mac Relay Sync Status**: New status widgets in the Dashboard and Settings show last-sync time with manual Sync Now / Full Resync / Reset controls.
*   **Message Composer**: Selecting a recipient from search now visibly confirms the selection.

## Bug Fixes

*   **Web of Trust Getting Stuck**: A stale Web of Trust snapshot could silently reject real replies and reactions as untrusted for days at a time. It now checks its own freshness on launch and refreshes itself in the background when due.
*   **Notifications Missing After Catching Up**: Activity that arrived only through the Mac Relay catch-up sync (rather than live) wasn't triggering notifications at all. Fixed.
*   **Local Relay Becoming Unreachable**: Mac Relay Sync could, in rare conditions, fire repeatedly and overwhelm the local relay badly enough that posting stopped working entirely. Fixed with a cooldown between sync rounds.
*   **Mac Relay Private/Chat Catch-Up Silently Failing**: These required an authentication step that was never being performed, so catch-up against them always failed quietly. Fixed.

## Removed

*   Remote push server registration and all associated APNs plumbing
