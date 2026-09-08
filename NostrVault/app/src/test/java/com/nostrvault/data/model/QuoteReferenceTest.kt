package com.nostrvault.data.model

import com.nostrvault.util.Bech32
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class QuoteReferenceTest {

    private val eventId = "5c83da77af1dec6d7289834998ad7aafbd9e2191396d75ec3cc27f5a77226f36"
    private val pubkey = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"

    private fun hexToBytes(hex: String) =
        ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    private fun tlv(vararg entries: Pair<Int, ByteArray>): ByteArray {
        val out = mutableListOf<Byte>()
        for ((type, value) in entries) {
            out.add(type.toByte())
            out.add(value.size.toByte())
            out.addAll(value.toList())
        }
        return out.toByteArray()
    }

    private fun kindBytes(kind: Int) = byteArrayOf(
        ((kind ushr 24) and 0xFF).toByte(),
        ((kind ushr 16) and 0xFF).toByte(),
        ((kind ushr 8) and 0xFF).toByte(),
        (kind and 0xFF).toByte(),
    )

    // ── note1 / nevent1 → hex event id ───────────────────────────────

    @Test
    fun `note1 decodes to its hex event id`() {
        val note1 = Bech32.encode("note", hexToBytes(eventId))
        assertEquals(eventId, QuoteReference.identifierFor(note1))
    }

    @Test
    fun `nevent1 decodes to the event id in its type-0 entry`() {
        val payload = tlv(
            0 to hexToBytes(eventId),
            2 to hexToBytes(pubkey),
            3 to kindBytes(1),
        )
        assertEquals(eventId, QuoteReference.identifierFor(Bech32.encode("nevent", payload)))
    }

    @Test
    fun `nevent1 with a relay hint before the event id still decodes`() {
        val payload = tlv(
            1 to "wss://relay.example".toByteArray(),
            0 to hexToBytes(eventId),
        )
        assertEquals(eventId, QuoteReference.identifierFor(Bech32.encode("nevent", payload)))
    }

    @Test
    fun `nevent1 carrying no event id yields nothing`() {
        val payload = tlv(2 to hexToBytes(pubkey), 3 to kindBytes(1))
        assertNull(QuoteReference.identifierFor(Bech32.encode("nevent", payload)))
    }

    // ── naddr1 → coordinate ──────────────────────────────────────────

    @Test
    fun `naddr1 decodes to a kind pubkey d-tag coordinate`() {
        val payload = tlv(
            0 to "my-article".toByteArray(),
            2 to hexToBytes(pubkey),
            3 to kindBytes(30023),
        )
        assertEquals(
            "naddr:30023:$pubkey:my-article",
            QuoteReference.identifierFor(Bech32.encode("naddr", payload)),
        )
    }

    @Test
    fun `naddr1 without a d-tag coordinates to an empty one`() {
        val payload = tlv(2 to hexToBytes(pubkey), 3 to kindBytes(30023))
        assertEquals(
            "naddr:30023:$pubkey:",
            QuoteReference.identifierFor(Bech32.encode("naddr", payload)),
        )
    }

    @Test
    fun `naddr1 missing its kind names no event`() {
        val payload = tlv(0 to "slug".toByteArray(), 2 to hexToBytes(pubkey))
        assertNull(QuoteReference.identifierFor(Bech32.encode("naddr", payload)))
    }

    @Test
    fun `naddr1 missing its pubkey names no event`() {
        val payload = tlv(0 to "slug".toByteArray(), 3 to kindBytes(30023))
        assertNull(QuoteReference.identifierFor(Bech32.encode("naddr", payload)))
    }

    @Test
    fun `a truncated TLV entry ends the walk instead of being read past`() {
        // Declares 32 bytes of pubkey and supplies 4.
        val payload = byteArrayOf(3, 4) + kindBytes(30023) + byteArrayOf(2, 32, 1, 2, 3, 4)
        assertNull(QuoteReference.identifierFor(Bech32.encode("naddr", payload)))
    }

    // ── coordinate round trip ────────────────────────────────────────

    @Test
    fun `a coordinate parses back into the parts it was built from`() {
        val id = QuoteReference.coordinate(30023, pubkey, "why-nostr")
        val parsed = QuoteReference.parseCoordinate(id)
        assertEquals(QuoteReference.Coordinate(30023, pubkey, "why-nostr"), parsed)
    }

    @Test
    fun `a d-tag containing colons survives the round trip`() {
        val dTag = "2026:09:my-post"
        val id = QuoteReference.coordinate(30023, pubkey, dTag)
        assertEquals(dTag, QuoteReference.parseCoordinate(id)?.dTag)
    }

    @Test
    fun `a hex event id is not mistaken for a coordinate`() {
        assertNull(QuoteReference.parseCoordinate(eventId))
        assertFalse(QuoteReference.isCoordinate(eventId))
        assertTrue(QuoteReference.isCoordinate(QuoteReference.coordinate(30023, pubkey, "x")))
    }

    // ── identifiers(content) ─────────────────────────────────────────

    @Test
    fun `identifiers returns every reference in the order it appears`() {
        val note1 = Bech32.encode("note", hexToBytes(eventId))
        val otherId = "a".repeat(64)
        val note2 = Bech32.encode("note", hexToBytes(otherId))
        val content = "look at nostr:$note2 and also nostr:$note1 today"
        assertEquals(listOf(otherId, eventId), QuoteReference.identifiers(content))
    }

    @Test
    fun `the same reference twice yields one identifier`() {
        val note1 = Bech32.encode("note", hexToBytes(eventId))
        assertEquals(
            listOf(eventId),
            QuoteReference.identifiers("nostr:$note1 and again nostr:$note1"),
        )
    }

    @Test
    fun `an undecodable reference is dropped rather than passed through`() {
        // Right shape, wrong checksum: this is exactly what used to reach the
        // relay as an event id that could never exist.
        assertEquals(emptyList<String>(), QuoteReference.identifiers("nostr:note1qqqqqqqqqqqqqq"))
    }

    @Test
    fun `content with no references yields nothing`() {
        assertEquals(emptyList<String>(), QuoteReference.identifiers("just some text #hashtag"))
    }

    // ── the regression this whole type exists for ────────────────────

    @Test
    fun `every identifier a note produces is one the resolver can read back`() {
        val note1 = Bech32.encode("note", hexToBytes(eventId))
        val naddr = Bech32.encode(
            "naddr",
            tlv(0 to "slug".toByteArray(), 2 to hexToBytes(pubkey), 3 to kindBytes(30023)),
        )
        val note = FeedNote(
            id = "f".repeat(64),
            pubkey = pubkey,
            content = "nostr:$note1 nostr:$naddr",
            createdAt = java.util.Date(0),
            tags = emptyList(),
            kind = 1,
        )

        assertEquals(2, note.quotedEventIds.size)
        for (identifier in note.quotedEventIds) {
            // Either a hex event id or a coordinate the fetcher can build a
            // filter from — never a bech32 string, which is what silently broke
            // every lookup before.
            if (QuoteReference.isCoordinate(identifier)) {
                assertTrue(QuoteReference.parseCoordinate(identifier) != null)
            } else {
                assertEquals(64, identifier.length)
                assertTrue(identifier.all { it in "0123456789abcdef" })
            }
        }
    }
}
