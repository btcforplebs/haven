# Haven App v2.6.0 Build 14 (macOS / iOS) Release Notes

This release fixes the sync loop that pegged the Mac relay at 100% CPU after about a day and fired a notification every minute, closes a hole that let anyone fake zap totals, repairs authentication on the local relay, and stops posts with media failing on the first attempt. The Mac app also uses noticeably less memory in the background and can finally be installed on a Mac other than the one that built it.

## Security

*   **Zap Totals Could Be Faked**: A zap receipt is an ordinary Nostr event, and the apps counted every one they saw without checking it. Anyone able to reach a relay your app queried could publish a receipt claiming any amount against any note or profile. Receipts are now validated against the recipient's Lightning provider — the pubkey that published the receipt must be the one that provider authorizes. Validation deliberately fails open when that can't be determined (no Lightning address, network error, or a provider that doesn't advertise one), so legitimate zaps are never dropped.

## Improvements

*   **Catch-Up Sync Slowed to a Sane Interval**: The default moves from every 60 seconds to every 15 minutes, with a hard minimum so an old saved setting can't bring the old behaviour back.
*   **Lower Background Memory (macOS)**: The relay returns memory to the system the moment the app goes to the background, instead of waiting for the next sync or import — on an idle relay that could be an hour away. About a quarter lower in steady state.
*   **Installable on Other Macs**: Every previous macOS build was signed so that it only ran on the machine that built it; on any other Mac it was terminated at launch with no explanation and no crash report. Builds are now signed for distribution. A downloaded copy still needs its quarantine flag cleared once until notarization is set up.
*   **Default Relay List**: `relay.damus.io` was removed from the defaults after it began refusing sync queries and rate-limiting connections. Relays you configured yourself are untouched.
*   **Matching Version Numbers**: macOS, iOS and Android now all report 2.6.0 (14), instead of three different version numbers for the same release.

## Bug Fixes

*   **Mac Relay Hitting 100% CPU After a Day**: Catch-up sync rebuilt its entire comparison set for every relay on every 60-second round, re-downloaded backlog it had already rejected, and re-probed relays that always refuse. Once the databases grew enough that a round outlasted its own interval, rounds ran back-to-back indefinitely. Now built once per round and reused, with rejected events remembered and refusing relays cached.
*   **A Notification Every Minute**: The same loop fired a fresh summary each round. On iOS, the "Catching up" summary was also triggered by ordinary background resyncs rather than only when returning after being away.
*   **Posting With Media Failed on the First Try**: Uploads nearly always failed once and worked on retry, because the default mirrors had gone dead and the Mac relay mirror was asleep until the failed attempt woke it. Mirrors are now warmed when the composer opens and the upload retries once before failing.
*   **Authentication Broken on the Local Relay (macOS)**: The relay checked authentication against a secure address while macOS serves the local relay unencrypted, so authentication always failed and every read requiring it was silently rejected.
*   **Profile Notes Fetched From the Wrong Relays**: Loading someone's notes queried the relays they *read* from rather than the ones they publish to, so profiles could look emptier than they are.
*   **Reposting Articles**: Long-form articles were reposted using the note-only event kind, producing something most clients ignore.
*   **Replies Vanishing From Their Own Threads**: In threads with seven or more participants, short replies tripped the mention-spam filter and disappeared — including your own.
*   **Blocking Didn't Take Effect Until Restart**: Blocking hid content from view immediately, but the relay was never told, so it kept importing and notifying about that person all session.
*   **Notifications for Old Backlog**: Catching up on old events could light the activity dot and fire notifications as if they were new.
*   **Multi-Account Corruption**: Routine background publishing briefly switched the active account internally, which every part of the app read as a real account switch and responded to by wiping loaded events.
*   **Multi-Relay Signer Connections**: A `bunker://` link listing several relays kept only the first, leaving reconnects with no fallback.
*   **Silent Video Failures**: When every source for a video failed, the feed showed a black rectangle instead of its thumbnail and offered no error or retry. Failures are now surfaced and "Try Again" works.
*   **Stall When Playing Cached Video**: Integrity-checking a cached video read and hashed up to 64 MB on the main thread, which could visibly hitch scrolling.
*   **Audio Interrupted During Picture-in-Picture**: Scrolling the feed while a video played full-screen or in PiP handed the audio session to the muted feed player.
*   **A Single Bad Setting Could Prevent Startup**: A malformed or blank value in the relay's configuration — twenty settings qualified, including the relay port — made the app quit during startup with no error and no crash report. Bad values now fall back to their default.
