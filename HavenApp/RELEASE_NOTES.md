# Haven App v2.6.0 Build 14 (macOS) / v2.6.0 Build 14 (iOS) Release Notes

A stability and correctness update. Video failures on iOS no longer disappear into a black rectangle, playing a cached video no longer stalls the interface, the Mac app uses noticeably less memory sitting in the background — and it can finally be installed on a Mac other than the one that built it.

## Improvements

*   **Lower Background Memory (macOS)**: The relay now returns memory to the system the moment the app goes to the background, instead of waiting for the next sync or import to come around — on an idle relay that could be an hour away. Measured about a quarter lower in steady state.
*   **Installable on Other Macs**: Every previous macOS build was signed in a way that only allowed it to run on the machine that built it — on any other Mac it was terminated at launch with no explanation and no crash report. Builds are now signed for distribution and run anywhere. A downloaded copy still needs its quarantine flag cleared once until notarization is set up.
*   **Matching Version Numbers**: The iOS app reported 1.1.1 while macOS reported 2.6.0 at the same build number. Both now read 2.6.0, so you can tell at a glance which build you have.

## Bug Fixes

*   **Video Failures Were Invisible**: When every source for a video failed, the feed showed a black rectangle instead of falling back to its thumbnail, full-screen went black, and no error or retry appeared anywhere. Failures are now surfaced, the feed falls back to its thumbnail, and "Try Again" works.
*   **Stall When Playing Cached Video**: Checking a cached video's integrity meant reading and hashing up to 64 MB on the main thread every time a player was created, which could visibly hitch scrolling. That work now happens in the background.
*   **Audio Interrupted During Picture-in-Picture**: Scrolling the feed while a video played full-screen or in PiP handed the audio session over to the muted feed player, cutting the audio of the video you were watching.
*   **Video Stuck Streaming After One Bad Copy**: If a cached video failed to play once, that video streamed from the network for the rest of the session — even after the bad copy was replaced with a good one.
*   **A Single Bad Setting Could Prevent Startup**: If any numeric or true/false value in the relay's configuration was malformed or blank — twenty settings qualified, including the relay port — the app quit during startup with no error and no crash report. Bad values now fall back to their default and record which setting was at fault.
