# NostrVault v1.2.1 (Build 6) Release Notes

An important fix for Android 10, 11, 12 and 13: on those versions the relay never actually started. It failed silently and reported itself as offline, with nothing to indicate why.

## Bug Fixes

*   **Relay Never Started on Android 10–13**: The background service asked the system for a service type that only exists on Android 14 and later. On Android 10 through 13 the system rejected that request, the error was caught and turned into a normal-looking "offline" state, and the relay simply never ran. If you are on one of those versions, this is the update that makes the app work at all. Android 14+ was unaffected.
*   **Stale Values in Dashboard & Feed Settings**: The cache location, cache duration, feed relay list and autoplay toggle were read in a way that never refreshed, so those screens could keep showing outdated settings after you changed them.
*   **A Single Bad Setting Could Prevent Startup**: If any numeric or true/false value in the relay's configuration was malformed or blank — twenty settings qualified, including the relay port — the app quit during startup with no error and no crash report. Bad values now fall back to their default and record which setting was at fault.
*   **Release Build Was Broken**: The app had not compiled from a clean checkout since 2026-07-16, after a relay-list cleanup left an incomplete statement behind. Also cleared every remaining compiler warning.
