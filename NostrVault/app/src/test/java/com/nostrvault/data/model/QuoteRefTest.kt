package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [QuoteRef] is the one definition of what a note quotes. These pin the two
 * properties that were broken when there were several: that a key the parser
 * produces is a key the fetcher accepts, and that an naddr survives the trip.
 */
class QuoteRefTest {

    // Real-length bech32 bodies. The parser now requires them: an unprefixed
    // reference is only safe to match because no ordinary word is this long and
    // made only of bech32 characters, so a three-letter stand-in would be
    // testing a string the app would rightly ignore.
    private val note1 = "note1" + "q9x8gf2tvdw0s3jn54khce6mua7lqpzry".repeat(2)
    private val nevent1 = "nevent1" + "gf2tvdw0s3jn54khce6mua7lqpzry9x8".repeat(2)
    private val naddr1 = "naddr1" + "s3jn54khce6mua7lqpzry9x8gf2tvdw0".repeat(2)
    private val unknown1 = "note1" + "zzzz54khce6mua7lqpzry9x8gf2tvdw0".repeat(2)

    private val eventHex = "a".repeat(64)
    private val otherHex = "b".repeat(64)
    private val authorHex = "c".repeat(64)

    /** Decodes by prefix alone, so the tests need no bech32 and no native library. */
    private val decoder = object : QuoteRef.Decoder {
        override fun noteToHex(note1: String) =
            if (note1 == this@QuoteRefTest.note1) eventHex else null

        override fun neventToHex(nevent1: String) =
            if (nevent1 == this@QuoteRefTest.nevent1) otherHex else null

        override fun naddrToAddress(naddr1: String) =
            if (naddr1 == this@QuoteRefTest.naddr1) {
                QuoteRef.Address(
                    QuoteRef.Coordinate(30023, authorHex, "my-post"),
                    listOf("wss://articles.example.com"),
                )
            } else {
                null
            }
    }

    // ── The regression: parser output must be fetcher input ──────────

    @Test
    fun `every key the parser produces is a key the fetcher can read`() {
        val content = "look nostr:$note1 and nostr:$nevent1 and nostr:$naddr1"

        val keys = QuoteRef.resolvedIdentifiers(content, decoder)

        assertEquals(3, keys.size)
        // The bug: FeedService decoded these as bech32, so every one came back
        // null and no quoted note ever resolved. Each must now name something.
        for (key in keys) {
            assertTrue("no key for $key", QuoteRef.key(key) != null)
        }
    }

    @Test
    fun `a hex event id reads as an event, not as nothing`() {
        assertEquals(QuoteRef.Key.Event(eventHex), QuoteRef.key(eventHex))
    }

    @Test
    fun `a coordinate reads as an address`() {
        val coordinate = QuoteRef.Coordinate(30023, authorHex, "my-post")
        val key = QuoteRef.key(QuoteRef.format(coordinate))
        assertEquals(QuoteRef.Key.Address(coordinate), key)
    }

    @Test
    fun `a key that is neither is rejected`() {
        assertNull(QuoteRef.key("nostr:$note1"))
        assertNull(QuoteRef.key(""))
        assertNull(QuoteRef.key("zz" + "a".repeat(62)))
    }

    // ── naddr ────────────────────────────────────────────────────────

    @Test
    fun `an naddr resolves to its coordinate`() {
        assertEquals(
            listOf("naddr:30023:$authorHex:my-post"),
            QuoteRef.resolvedIdentifiers("read nostr:$naddr1", decoder),
        )
    }

    @Test
    fun `a coordinate survives a round trip`() {
        val coordinate = QuoteRef.Coordinate(30023, authorHex, "my-post")
        assertEquals(coordinate, QuoteRef.parse(QuoteRef.format(coordinate)))
    }

    @Test
    fun `a d tag containing a colon survives`() {
        val coordinate = QuoteRef.Coordinate(30023, authorHex, "2026:09:08-notes")
        assertEquals(coordinate, QuoteRef.parse(QuoteRef.format(coordinate)))
    }

    @Test
    fun `an empty d tag is a real identifier, not a missing one`() {
        val coordinate = QuoteRef.Coordinate(30023, authorHex, "")
        assertEquals(coordinate, QuoteRef.parse(QuoteRef.format(coordinate)))
    }

    @Test
    fun `parse rejects a plain event id`() {
        assertNull(QuoteRef.parse(eventHex))
    }

    @Test
    fun `parse rejects a coordinate with no author`() {
        assertNull(QuoteRef.parse("naddr:30023::my-post"))
    }

    @Test
    fun `parse rejects a coordinate with a non-numeric kind`() {
        assertNull(QuoteRef.parse("naddr:article:$authorHex:my-post"))
    }

    // ── Extraction ───────────────────────────────────────────────────

    @Test
    fun `identifiers keep their order and drop repeats`() {
        val content = "nostr:$nevent1 then nostr:$note1 then nostr:$nevent1 again"
        assertEquals(listOf(nevent1, note1), QuoteRef.identifiers(content))
    }

    @Test
    fun `a reference that will not decode is dropped, not passed through`() {
        // Passing the bech32 through is the original bug: it asked the relay
        // for an id that cannot exist.
        assertEquals(emptyList<String>(), QuoteRef.resolvedIdentifiers("nostr:$unknown1", decoder))
    }

    @Test
    fun `profile mentions are not quote references`() {
        assertEquals(emptyList<String>(), QuoteRef.identifiers("hi nostr:npub1${"q9x8gf2tvdw0s3jn54khce6mua7l".repeat(2)}"))
    }

    @Test
    fun `two references to the same event yield one key`() {
        val content = "nostr:$note1 and again nostr:$note1"
        assertEquals(listOf(eventHex), QuoteRef.resolvedIdentifiers(content, decoder))
    }

    // ── References without the `nostr:` prefix ───────────────────────

    @Test
    fun `a bare nevent is a quote reference`() {
        // Some clients post the identifier alone. It used to be matched by
        // nothing: no card was drawn and the text was not stripped either, so
        // it sat in the note as a wall of bech32.
        assertEquals(listOf(nevent1), QuoteRef.identifiers("look at this $nevent1"))
    }

    @Test
    fun `a bare reference at the very start of a note is found`() {
        assertEquals(listOf(note1), QuoteRef.identifiers("$note1 is worth reading"))
    }

    @Test
    fun `the nostr prefix still works and is not part of the identifier`() {
        assertEquals(listOf(note1), QuoteRef.identifiers("see nostr:$note1"))
    }

    @Test
    fun `a reference inside a URL is left alone`() {
        // The renderer deletes whatever this matches, so matching inside a link
        // would delete the link. njump-style URLs carry these constantly.
        assertEquals(
            emptyList<String>(),
            QuoteRef.identifiers("read it at https://njump.me/$nevent1 today"),
        )
    }

    @Test
    fun `a short lookalike is not a reference`() {
        // "note1" followed by a few characters is a plausible thing to type.
        // No real note1/nevent1/naddr1 is anywhere near this short.
        assertEquals(emptyList<String>(), QuoteRef.identifiers("see note1qqqq and nevent1qq"))
    }

    // ── Relay hints ──────────────────────────────────────────────────

    @Test
    fun `an naddr hands over the relay hint it carries`() {
        // Without this the article is only ever asked of the reader's own
        // relays, and a card quoting an article published elsewhere stays on
        // "Loading quoted note..." with nothing wrong in the decode.
        assertEquals(
            mapOf("naddr:30023:$authorHex:my-post" to listOf("wss://articles.example.com")),
            QuoteRef.relayHints("read nostr:$naddr1", decoder),
        )
    }

    @Test
    fun `hints are keyed by the same key the fetcher looks up`() {
        val content = "read nostr:$naddr1"
        val key = QuoteRef.resolvedIdentifiers(content, decoder).single()
        assertTrue(QuoteRef.relayHints(content, decoder).containsKey(key))
    }

    @Test
    fun `a note with no addressable quote carries no hints`() {
        assertTrue(QuoteRef.relayHints("nostr:$note1", decoder).isEmpty())
    }

    @Test
    fun `the same article quoted twice yields one hinted key`() {
        val hints = QuoteRef.relayHints("nostr:$naddr1 and nostr:$naddr1", decoder)
        assertEquals(1, hints.size)
        assertEquals(listOf("wss://articles.example.com"), hints.values.single())
    }

    @Test
    fun `a hint is not part of the address`() {
        // Two notes may quote one article with different hints. If the hint
        // reached the key they would be two cache entries and two cards.
        val coordinate = QuoteRef.Coordinate(30023, authorHex, "my-post")
        assertEquals(
            QuoteRef.format(coordinate),
            QuoteRef.format(QuoteRef.Address(coordinate, listOf("wss://elsewhere.example")).coordinate),
        )
    }
}
