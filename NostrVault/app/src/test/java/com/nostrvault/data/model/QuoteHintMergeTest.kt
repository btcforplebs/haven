package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

/**
 * The quote fetch is batched across every note on screen, so the hints have to
 * be batched the same way: the same article quoted by two notes is one lookup,
 * and it should be able to use either note's hint.
 */
class QuoteHintMergeTest {

    private val key = "naddr:30023:${"c".repeat(64)}:my-post"

    private fun note(hints: Map<String, List<String>>) = FeedNote(
        id = "a".repeat(64),
        pubkey = "b".repeat(64),
        content = "",
        createdAt = Date(0),
        tags = emptyList(),
        kind = 1,
        isReply = false,
        replyToPubkey = null,
        parentEventId = null,
        mediaURLs = emptyList(),
        linkURLs = emptyList(),
        quotedEventIds = hints.keys.toList(),
        repostedEventId = null,
        quotedRelayHints = hints,
    )

    @Test
    fun `hints from different notes for one article are pooled`() {
        val merged = FeedNote.mergedQuoteRelayHints(
            listOf(
                note(mapOf(key to listOf("wss://one.example"))),
                note(mapOf(key to listOf("wss://two.example"))),
            ),
        )
        assertEquals(mapOf(key to listOf("wss://one.example", "wss://two.example")), merged)
    }

    @Test
    fun `the same hint twice is one relay, not two sockets`() {
        val merged = FeedNote.mergedQuoteRelayHints(
            listOf(
                note(mapOf(key to listOf("wss://one.example"))),
                note(mapOf(key to listOf("wss://one.example"))),
            ),
        )
        assertEquals(listOf("wss://one.example"), merged.getValue(key))
    }

    @Test
    fun `notes that quote nothing addressable contribute nothing`() {
        assertTrue(FeedNote.mergedQuoteRelayHints(listOf(note(emptyMap()))).isEmpty())
    }

    @Test
    fun `a note decoded without hints still reads back`() {
        // The field is defaulted so a note cached before it existed still
        // decodes; nothing may require it to be present.
        val legacy = FeedNote(
            id = "a".repeat(64),
            pubkey = "b".repeat(64),
            content = "",
            createdAt = Date(0),
            tags = emptyList(),
            kind = 1,
            isReply = false,
            replyToPubkey = null,
            parentEventId = null,
            mediaURLs = emptyList(),
            linkURLs = emptyList(),
            quotedEventIds = emptyList(),
            repostedEventId = null,
        )
        assertTrue(legacy.quotedRelayHints.isEmpty())
    }
}
