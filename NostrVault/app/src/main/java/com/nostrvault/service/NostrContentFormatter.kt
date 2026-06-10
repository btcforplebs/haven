package com.nostrvault.service

import android.util.Log
import android.util.LruCache
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import com.nostrvault.relay.HavenBridge
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Nostr content formatter.
 * Resolves nostr: mention links (npub, nprofile, note, nevent, naddr),
 * linkifies URLs, and strips media URLs from display.
 *
 * Port of NostrContentFormatter.swift.
 */
@Singleton
class NostrContentFormatter @Inject constructor(
    private val nostrService: NostrService,
) {
    companion object {
        private const val TAG = "ContentFormatter"
        private const val CACHE_MAX = 200

        // Pre-compiled regex patterns
        private val NPUB_REGEX = Regex("""nostr:(npub1[a-z0-9]+)""")
        private val NPROFILE_REGEX = Regex("""nostr:(nprofile1[a-z0-9]+)""")
        private val NOTE_REGEX = Regex("""nostr:(note1[a-z0-9]+)""")
        private val NEVENT_REGEX = Regex("""nostr:(nevent1[a-z0-9]+)""")
        private val NADDR_REGEX = Regex("""nostr:(naddr1[a-z0-9]+)""")
        private val HTTP_URL_REGEX = Regex("""(?<!\()https?://[^\s)\]>"]+""")
        private val MEDIA_URL_REGEX = Regex(
            """https?://\S+\.(jpg|jpeg|png|gif|webp|mp4|mov|webm|mp3|wav|ogg)(\?\S*)?""",
            RegexOption.IGNORE_CASE,
        )
    }

    private val cache = LruCache<String, AnnotatedString>(CACHE_MAX)

    // ══════════════════════════════════════════════════════════════════
    // Main formatting
    // ══════════════════════════════════════════════════════════════════

    /**
     * Format Nostr content with mention resolution, URL linkification,
     * and media URL stripping.
     */
    fun format(
        content: String,
        mediaURLs: Set<String> = emptySet(),
        hideQuotes: Boolean = false,
    ): AnnotatedString {
        val cacheKey = "$content|${mediaURLs.hashCode()}|$hideQuotes"
        cache.get(cacheKey)?.let { return it }

        val result = formatUncached(content, mediaURLs, hideQuotes)
        cache.put(cacheKey, result)
        return result
    }

    private fun formatUncached(
        content: String,
        mediaURLs: Set<String>,
        hideQuotes: Boolean,
    ): AnnotatedString {
        var text = content

        // Strip media URLs
        if (mediaURLs.isNotEmpty()) {
            for (url in mediaURLs) {
                text = text.replace(url, "")
            }
        }

        // Also strip embedded media URLs from content
        text = MEDIA_URL_REGEX.replace(text, "")

        // Collapse multiple blank lines
        text = text.replace(Regex("""\n{3,}"""), "\n\n").trim()

        // Resolve mentions to display names
        text = resolveNpubMentions(text)
        text = resolveNprofileMentions(text)
        text = resolveNoteMentions(text)
        text = resolveNeventMentions(text)
        text = resolveNaddrMentions(text)

        // Build annotated string with clickable links
        return buildAnnotatedString(text)
    }

    // ══════════════════════════════════════════════════════════════════
    // Mention resolution
    // ══════════════════════════════════════════════════════════════════

    private fun resolveNpubMentions(text: String): String {
        return NPUB_REGEX.replace(text) { matchResult ->
            val npub = matchResult.groupValues[1]
            val hex = nostrService.npubToHex(npub)
            val name = hex?.let { nostrService.profiles.value[it]?.bestName }

            if (name != null) {
                "[@$name](nostr:$npub)"
            } else {
                // Trigger profile fetch for unknown pubkeys
                hex?.let { nostrService.fetchMissingProfiles(listOf(it)) }
                "[@${npub.take(8)}...${npub.takeLast(4)}](nostr:$npub)"
            }
        }
    }

    private fun resolveNprofileMentions(text: String): String {
        return NPROFILE_REGEX.replace(text) { matchResult ->
            val nprofile = matchResult.groupValues[1]
            val hex = try {
                HavenBridge.decodeNprofile(nprofile)
            } catch (e: Exception) { null }

            val name = hex?.let { nostrService.profiles.value[it]?.bestName }
            if (name != null) {
                "[@$name](nostr:$nprofile)"
            } else {
                hex?.let { nostrService.fetchMissingProfiles(listOf(it)) }
                "[@${nprofile.take(12)}...](nostr:$nprofile)"
            }
        }
    }

    private fun resolveNoteMentions(text: String): String {
        return NOTE_REGEX.replace(text) { matchResult ->
            val note = matchResult.groupValues[1]
            "[note:${note.take(8)}...](nostr:$note)"
        }
    }

    private fun resolveNeventMentions(text: String): String {
        return NEVENT_REGEX.replace(text) { matchResult ->
            val nevent = matchResult.groupValues[1]
            "[event:${nevent.take(8)}...](nostr:$nevent)"
        }
    }

    private fun resolveNaddrMentions(text: String): String {
        return NADDR_REGEX.replace(text) { matchResult ->
            val naddr = matchResult.groupValues[1]
            "[article:${naddr.take(8)}...](nostr:$naddr)"
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // AnnotatedString builder
    // ══════════════════════════════════════════════════════════════════

    /**
     * Build an AnnotatedString with clickable links and bold mentions.
     */
    private fun buildAnnotatedString(text: String): AnnotatedString {
        return buildAnnotatedString {
            val markdownLinkRegex = Regex("""\[([^\]]+)\]\(([^)]+)\)""")
            var lastIndex = 0

            for (match in markdownLinkRegex.findAll(text)) {
                // Append text before link
                if (match.range.first > lastIndex) {
                    append(text.substring(lastIndex, match.range.first))
                }

                val label = match.groupValues[1]
                val url = match.groupValues[2]

                // Annotate the link
                pushStringAnnotation(tag = "URL", annotation = url)
                withStyle(SpanStyle(fontWeight = FontWeight.Bold)) {
                    append(label)
                }
                pop()

                lastIndex = match.range.last + 1
            }

            // Append remaining text
            if (lastIndex < text.length) {
                val remaining = text.substring(lastIndex)
                // Linkify bare URLs in remaining text
                appendWithUrls(remaining)
            }
        }
    }

    private fun AnnotatedString.Builder.appendWithUrls(text: String) {
        var lastIndex = 0
        for (match in HTTP_URL_REGEX.findAll(text)) {
            if (match.range.first > lastIndex) {
                append(text.substring(lastIndex, match.range.first))
            }

            val url = match.value
            val domain = try {
                java.net.URI(url).host ?: url
            } catch (e: Exception) { url }

            pushStringAnnotation(tag = "URL", annotation = url)
            withStyle(SpanStyle(fontWeight = FontWeight.Normal)) {
                append(domain)
            }
            pop()

            lastIndex = match.range.last + 1
        }

        if (lastIndex < text.length) {
            append(text.substring(lastIndex))
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Plain text helpers
    // ══════════════════════════════════════════════════════════════════

    /**
     * Resolve mentions to plain text @Name format (no links).
     */
    fun resolveMentionsPlainText(content: String): String {
        var text = content
        text = NPUB_REGEX.replace(text) { match ->
            val npub = match.groupValues[1]
            val hex = nostrService.npubToHex(npub)
            val name = hex?.let { nostrService.profiles.value[it]?.bestName }
            "@${name ?: npub.take(12)}"
        }
        text = NPROFILE_REGEX.replace(text) { match ->
            val nprofile = match.groupValues[1]
            val hex = try { HavenBridge.decodeNprofile(nprofile) } catch (_: Exception) { null }
            val name = hex?.let { nostrService.profiles.value[it]?.bestName }
            "@${name ?: nprofile.take(12)}"
        }
        return text
    }

    /**
     * Clear the formatting cache (call on account switch).
     */
    fun clearCache() {
        cache.evictAll()
    }
}
