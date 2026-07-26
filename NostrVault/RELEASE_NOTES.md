# NostrVault v2.6.0 (Build 14) Release Notes

The headline fix is for Android 10, 11, 12 and 13: on those versions the relay never actually started. It failed silently and reported itself offline, with nothing to indicate why. This release also closes a hole that let anyone fake zap totals, stops private message send times leaking, repairs authentication on the local relay, and ends the sync loop that fired a notification every minute.

## Security

*   **Zap Totals Could Be Faked**: A zap receipt is an ordinary Nostr event, and the app counted every one it saw without checking it. Anyone able to reach a relay your app queried could publish a receipt claiming any amount against any note or profile. Receipts are now validated against the recipient's Lightning provider. Validation fails open when that can't be determined, so legitimate zaps are never dropped.
*   **Private Message Send Times Leaked**: Private messages were stamped with the true send time instead of the randomized timestamp the spec calls for, so anyone watching relays could tell exactly when you sent one. Now randomized, matching iOS.

## Improvements

*   **Catch-Up Sync Slowed to a Sane Interval**: The default moves from every 60 seconds to every 15 minutes, with a hard minimum so an old saved setting can't bring the old behaviour back. This was also firing a notification a minute.
*   **Default Relay List**: `relay.damus.io` was removed from the defaults after it began refusing sync queries and rate-limiting connections. Relays you configured yourself are untouched.
*   **Matching Version Numbers**: macOS, iOS and Android now all report 2.6.0 (14), instead of three different version numbers for the same release.

## Bug Fixes

*   **Relay Never Started on Android 10–13**: The background service asked the system for a service type that only exists on Android 14 and later. On Android 10 through 13 the system rejected that request, the error was caught and turned into a normal-looking "offline" state, and the relay simply never ran. If you are on one of those versions, this is the update that makes the app work at all. Android 14+ was unaffected.
*   **Authentication Broken on the Local Relay**: The relay checked authentication against a secure address while Android serves the local relay unencrypted, so authentication always failed and every read requiring it was silently rejected.
*   **Posting With Media Failed on the First Try**: Uploads nearly always failed once and worked on retry, because the default mirrors had gone dead and the Mac relay mirror was asleep until the failed attempt woke it. Mirrors are now warmed when the composer opens and the upload retries once. The app also no longer quietly embeds an unreachable local link in a note when every mirror fails — it reports the failure.
*   **Replies Not Notifying Everyone in a Thread**: Replies only tagged the person you replied to, leaving everyone else in the conversation out.
*   **Replies Vanishing From Their Own Threads**: In threads with seven or more participants, short replies tripped the mention-spam filter and disappeared — including your own.
*   **Reposting Articles**: Long-form articles were reposted using the note-only event kind, producing something most clients ignore. Reposts were also missing the relay hint and original author tag.
*   **Profile Notes Fetched From the Wrong Relays**: Loading someone's notes queried the relays they *read* from rather than the ones they publish to, so profiles could look emptier than they are.
*   **Blocking Didn't Take Effect Until Restart**: Blocking hid content from view immediately, but the relay was never told, so it kept importing and notifying about that person all session.
*   **Notifications for Old Backlog**: Catching up on old events could light the activity dot and fire notifications as if they were new.
*   **Stale Values in Dashboard & Feed Settings**: The cache location, cache duration, feed relay list and autoplay toggle never refreshed, so those screens could show outdated settings after you changed them.
*   **A Single Bad Setting Could Prevent Startup**: A malformed or blank value in the relay's configuration — twenty settings qualified, including the relay port — made the app quit during startup with no error and no crash report. Bad values now fall back to their default.
*   **Release Build Was Broken**: The app had not compiled from a clean checkout since 2026-07-16, after a relay-list cleanup left an incomplete statement behind.
