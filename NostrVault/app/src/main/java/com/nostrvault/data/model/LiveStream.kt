package com.nostrvault.data.model

/**
 * A NIP-53 live event (kind 30311), reduced to what a grid and a player need.
 *
 * Parsing lives here, away from the networking, because the interesting
 * decisions are all about the tags: which streams are worth showing, and which
 * URLs can actually be played.
 */
data class LiveStream(
    val hostPubkey: String,
    val identifier: String,
    val createdAt: Long,
    val title: String?,
    val summary: String?,
    val imageUrl: String?,
    val streamingUrl: String?,
    val status: String?,
    val participants: Int?,
) {
    /** The addressable form: what an naddr for this stream points at. */
    val address: String get() = "$KIND:$hostPubkey:$identifier"

    /**
     * Shown only when the stream is running AND something can play it.
     *
     * iOS measured this against a real sample (2026-09-05): 478 of 632 events
     * were already `ended` and only 89 carried a streaming tag at all, so
     * without both halves of the test the grid is mostly gravestones. A
     * missing status with a playable URL counts — 71 events omit status
     * entirely, which is a real bucket rather than noise.
     */
    val isPlayableLive: Boolean
        get() = streamingUrl != null && (status == null || status == "live")

    companion object {
        const val KIND = 30311

        /** @return null when the event is not a usable live event (no `d` tag). */
        fun from(pubkey: String, createdAt: Long, tags: List<List<String>>): LiveStream? {
            fun value(name: String): String? = tags
                .firstOrNull { it.size >= 2 && it[0] == name }
                ?.get(1)
                ?.trim()
                ?.takeIf { it.isNotEmpty() }

            val identifier = value("d") ?: return null

            // ExoPlayer speaks HTTP(S). Real events also carry rtmp, ftp and
            // even `zapcast:` URLs, none of which it can open — a tile for one
            // of those is a tile that can only disappoint.
            val streaming = value("streaming")?.takeIf { raw ->
                val scheme = raw.substringBefore(':').lowercase()
                scheme == "http" || scheme == "https"
            }

            return LiveStream(
                hostPubkey = pubkey,
                identifier = identifier,
                createdAt = createdAt,
                title = value("title"),
                summary = value("summary"),
                imageUrl = value("image"),
                streamingUrl = streaming,
                status = value("status")?.lowercase(),
                participants = value("current_participants")?.toIntOrNull(),
            )
        }
    }
}
