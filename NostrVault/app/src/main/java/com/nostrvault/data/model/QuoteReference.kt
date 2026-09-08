package com.nostrvault.data.model

import com.nostrvault.util.Bech32

/**
 * The `nostr:` references a note makes to other events, and the single string
 * form the rest of the app uses to name one.
 *
 * There is exactly one representation, because there used to be two and they
 * drifted: the parser was changed to decode bech32 to a hex event id while both
 * of its consumers still required a `note1`/`nevent1` prefix, so every lookup
 * returned null and no quoted note ever resolved. An identifier here is either
 *
 *  - a 64-character hex event id (from `note1` or `nevent1`), or
 *  - a `naddr:<kind>:<pubkey>:<d-tag>` coordinate (from `naddr1`), naming an
 *    addressable NIP-33 event that is fetched by kind/author/`d` rather than id.
 *
 * Everything here is pure string and TLV work — no relay, no Android — so it is
 * unit testable. That is also why the bech32 layer lives in [Bech32] rather than
 * in `HavenBridge`, which cannot be loaded outside a device.
 */
object QuoteReference {

    /** Marks an addressable-event coordinate rather than a 32-byte event id. */
    const val COORDINATE_PREFIX = "naddr:"

    /** `nostr:note1…` / `nostr:nevent1…` / `nostr:naddr1…` event references. */
    val REGEX = Regex(
        """nostr:(note1[a-z0-9]+|nevent1[a-z0-9]+|naddr1[a-z0-9]+)""",
        RegexOption.IGNORE_CASE,
    )

    data class Coordinate(val kind: Int, val pubkey: String, val dTag: String)

    /**
     * Every quote reference in [content], in the order they appear, decoded to
     * identifiers, with repeats and undecodable references dropped.
     *
     * Repeats are dropped because these address rows in a list: the same
     * reference twice is the same card twice, and a `key`-ed list needs its keys
     * to be unique.
     */
    fun identifiers(content: String): List<String> =
        REGEX.findAll(content)
            .mapNotNull { identifierFor(it.groupValues[1]) }
            .distinct()
            .toList()

    /** The identifier a single bech32 reference names, or null if it will not decode. */
    fun identifierFor(bech32: String): String? {
        val (hrp, payload) = Bech32.decode(bech32) ?: return null
        return when (hrp) {
            "note" -> if (payload.size == 32) payload.toHex() else null
            "nevent" -> eventIdFromNeventTLV(payload)
            "naddr" -> coordinateFromNaddrTLV(payload)
            else -> null
        }
    }

    /** True when [identifier] names an addressable event rather than an event id. */
    fun isCoordinate(identifier: String): Boolean = identifier.startsWith(COORDINATE_PREFIX)

    /** The event id carried by an `nevent` TLV payload — type 0, 32 bytes. */
    fun eventIdFromNeventTLV(payload: ByteArray): String? {
        for (entry in tlvEntries(payload)) {
            if (entry.type == 0 && entry.value.size == 32) return entry.value.toHex()
        }
        return null
    }

    /**
     * A coordinate from an `naddr` TLV payload.
     *
     * NIP-19 naddr TLV: type 0 = d-tag (UTF-8), 1 = relay, 2 = pubkey (32
     * bytes), 3 = kind (4 bytes, big endian). Kind and pubkey are both required
     * — without them the reference names no event. An empty d-tag is legal.
     */
    fun coordinateFromNaddrTLV(payload: ByteArray): String? {
        var dTag: String? = null
        var pubkey: String? = null
        var kind: Int? = null

        for (entry in tlvEntries(payload)) {
            when {
                entry.type == 0 -> dTag = String(entry.value, Charsets.UTF_8)
                entry.type == 2 && entry.value.size == 32 -> pubkey = entry.value.toHex()
                entry.type == 3 && entry.value.size == 4 ->
                    kind = entry.value.fold(0) { acc, b -> (acc shl 8) or (b.toInt() and 0xFF) }
            }
        }

        val k = kind ?: return null
        val p = pubkey ?: return null
        return coordinate(k, p, dTag ?: "")
    }

    /** Builds a coordinate string. One definition, so [parseCoordinate] cannot drift from it. */
    fun coordinate(kind: Int, pubkey: String, dTag: String): String =
        "$COORDINATE_PREFIX$kind:$pubkey:$dTag"

    /**
     * Splits a coordinate back into its parts, or null for anything that is not
     * one — a plain hex event id included.
     */
    fun parseCoordinate(identifier: String): Coordinate? {
        if (!isCoordinate(identifier)) return null
        // limit 4 keeps a d-tag containing ":" intact.
        val parts = identifier.split(":", limit = 4)
        if (parts.size < 3) return null
        val kind = parts[1].toIntOrNull() ?: return null
        if (parts[2].isEmpty()) return null
        return Coordinate(kind, parts[2], if (parts.size > 3) parts[3] else "")
    }

    // ── TLV ──────────────────────────────────────────────────────────

    private data class TLVEntry(val type: Int, val value: ByteArray)

    /**
     * Walks a NIP-19 TLV payload. A truncated entry ends the walk rather than
     * being read past — a malformed reference should yield nothing, not garbage.
     */
    private fun tlvEntries(payload: ByteArray): List<TLVEntry> {
        val entries = mutableListOf<TLVEntry>()
        var i = 0
        while (i + 2 <= payload.size) {
            val type = payload[i].toInt() and 0xFF
            val length = payload[i + 1].toInt() and 0xFF
            i += 2
            if (i + length > payload.size) break
            entries.add(TLVEntry(type, payload.copyOfRange(i, i + length)))
            i += length
        }
        return entries
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
}
