package com.nostrvault.ui.components

import com.nostrvault.data.model.FeedProfile
import com.nostrvault.relay.HavenBridge

/**
 * Shared NIP-19 mention resolution used by both the clickable [NostrContentText]
 * renderer and single-line plain-text previews, so they agree on how
 * `nostr:npub1.../nostr:nprofile1...` references resolve to a pubkey / display name.
 */
object NostrMentions {

    /** `nostr:npub1...` / `nostr:nprofile1...` profile mentions. */
    val MENTION_REGEX = Regex(
        """nostr:(npub1[a-z0-9]+|nprofile1[a-z0-9]+)""",
        RegexOption.IGNORE_CASE,
    )

    /** `nostr:note1...` / `nostr:nevent1...` / `nostr:naddr1...` event references. */
    val QUOTE_REGEX = Regex(
        """nostr:(note1[a-z0-9]+|nevent1[a-z0-9]+|naddr1[a-z0-9]+)""",
        RegexOption.IGNORE_CASE,
    )

    /** Resolve an npub/nprofile bech32 identifier to a hex pubkey. */
    fun resolvePubkey(identifier: String): String? {
        return when {
            identifier.startsWith("npub1", ignoreCase = true) -> HavenBridge.decodeNpub(identifier)
            identifier.startsWith("nprofile1", ignoreCase = true) -> {
                // decodeNprofile returns JSON: {"pubkey":"...","relays":[...]}
                val json = HavenBridge.decodeNprofile(identifier) ?: return null
                val keyStart = json.indexOf("\"pubkey\":\"")
                if (keyStart < 0) return null
                val start = keyStart + 10
                val end = json.indexOf("\"", start)
                if (end < 0) null else json.substring(start, end)
            }
            else -> null
        }
    }

    /** Display label for a mention: the profile's best name, else a short pubkey. */
    private fun displayName(pubkey: String, profiles: Map<String, FeedProfile>): String =
        profiles[pubkey]?.bestName ?: "${pubkey.take(8)}…"

    /**
     * Resolve nostr mentions in [content] to plain `@name` text and strip
     * `nostr:note/nevent/naddr` quote references (rendered separately as cards).
     * Used for single-line preview rows where a clickable renderer is overkill.
     */
    fun toPlainText(content: String, profiles: Map<String, FeedProfile>): String {
        var text = MENTION_REGEX.replace(content) { match ->
            val identifier = match.groupValues[1]
            val pubkey = resolvePubkey(identifier)
            if (pubkey != null) "@${displayName(pubkey, profiles)}" else "@${identifier.take(10)}…"
        }
        text = QUOTE_REGEX.replace(text, "")
        return text.trim()
    }
}
