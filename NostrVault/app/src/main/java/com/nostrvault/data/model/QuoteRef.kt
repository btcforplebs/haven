package com.nostrvault.data.model

/**
 * The `nostr:` references a note makes to other events, and the key the app
 * looks each one up by.
 *
 * There is one definition here because there used to be three. The regex was
 * copied into the note parser, the text renderer and a formatter, and the
 * bech32 decode lived in two places that disagreed: the parser was changed to
 * hand out hex event ids while `FeedService` still expected bech32, so it
 * rejected every id it was given and no quoted note resolved at all. A parser
 * and its consumer cannot drift if they are the same code.
 *
 * bech32 decoding is injected via [Decoder] rather than calling HavenBridge
 * directly, so everything here is a plain JVM unit a test can drive.
 */
object QuoteRef {

    /**
     * The bech32 data charset, 40 characters or more.
     *
     * bech32 excludes `1`, `b`, `i` and `o` so they cannot be confused when
     * read aloud, and that exclusion is what makes an unprefixed reference
     * safe to match: ordinary words contain those letters.
     */
    private const val BECH32 = "[02-9ac-hj-np-z]{40,}"

    /**
     * `note1...` / `nevent1...` / `naddr1...` event references, with or without
     * the `nostr:` prefix.
     *
     * The prefix is optional because clients post both. A bare `nevent1...`
     * used to fall through every path here: not turned into a card, and not
     * stripped either, so it sat in the note as a wall of bech32.
     *
     * Two things keep that looseness safe. The body is the bech32 charset only
     * (no `b`, `i`, `o` or `1`) with a length floor no real word reaches — the
     * shortest legal reference of any of these three kinds is longer than this.
     * And the lookbehind refuses a match that is glued to the text before it,
     * which is what keeps `https://njump.me/nevent1...` a link: the renderer
     * strips whatever this matches, so matching inside a URL would delete it.
     */
    val REGEX = Regex(
        """(?<![A-Za-z0-9_/.@-])(?:nostr:)?(note1$BECH32|nevent1$BECH32|naddr1$BECH32)""",
        RegexOption.IGNORE_CASE,
    )

    /** Marks a lookup key as an addressable-event coordinate, not a 32-byte event id. */
    const val COORDINATE_PREFIX = "naddr:"

    /**
     * A NIP-01 addressable event's address: `kind`, author and `d` tag. A
     * long-form article is edited in place, so it is named by this rather than
     * by the id of any one revision.
     */
    data class Coordinate(val kind: Int, val pubkey: String, val dTag: String)

    /**
     * An addressable reference as written: the address it names, plus the relay
     * hints the reference carried.
     *
     * The hints are held here rather than inside [Coordinate] because they are
     * not part of the address. Two notes may quote the same article with
     * different hints, and they must still be one lookup key and one card.
     */
    data class Address(val coordinate: Coordinate, val relays: List<String> = emptyList())

    /** bech32 decoding, supplied by the caller. The real one wraps HavenBridge. */
    interface Decoder {
        fun noteToHex(note1: String): String?
        fun neventToHex(nevent1: String): String?
        fun naddrToAddress(naddr1: String): Address?
    }

    /** What a lookup key names. */
    sealed class Key {
        /** A 64-hex event id, fetched with an `ids` filter. */
        data class Event(val hexId: String) : Key()

        /** An addressable event, fetched with kind + author + `#d`. */
        data class Address(val coordinate: Coordinate) : Key()
    }

    /**
     * Every quote reference in [content], in the order they appear, repeats
     * dropped.
     *
     * Repeats are dropped because these address rows in a list: the same
     * reference twice is the same card twice.
     */
    fun identifiers(content: String): List<String> {
        val seen = LinkedHashSet<String>()
        for (match in REGEX.findAll(content)) seen.add(match.groupValues[1])
        return seen.toList()
    }

    /**
     * The lookup key for one bech32 identifier: a hex event id for
     * `note1`/`nevent1`, a coordinate for `naddr1`.
     */
    fun resolve(identifier: String, decoder: Decoder): String? = when {
        identifier.startsWith("note1", ignoreCase = true) ->
            decoder.noteToHex(identifier)
        identifier.startsWith("nevent1", ignoreCase = true) ->
            decoder.neventToHex(identifier)
        identifier.startsWith("naddr1", ignoreCase = true) ->
            decoder.naddrToAddress(identifier)?.let { format(it.coordinate) }
        else -> null
    }

    /** The lookup keys for every quote reference in [content]. */
    fun resolvedIdentifiers(content: String, decoder: Decoder): List<String> =
        identifiers(content).mapNotNull { resolve(it, decoder) }.distinct()

    /**
     * The relay hints carried by the addressable references in [content],
     * keyed by the same lookup key [resolvedIdentifiers] produces.
     *
     * Only `naddr1` carries hints that matter here: a long-form article is
     * usually on its author's relays and not the reader's, and without asking
     * the hinted relay the card never resolves. The map is keyed by lookup key
     * so a caller holding only keys — which is every caller — can find them.
     */
    fun relayHints(content: String, decoder: Decoder): Map<String, List<String>> {
        val hints = mutableMapOf<String, MutableList<String>>()
        for (identifier in identifiers(content)) {
            if (!identifier.startsWith("naddr1", ignoreCase = true)) continue
            val address = decoder.naddrToAddress(identifier) ?: continue
            if (address.relays.isEmpty()) continue
            val bucket = hints.getOrPut(format(address.coordinate)) { mutableListOf() }
            for (relay in address.relays) if (relay !in bucket) bucket.add(relay)
        }
        return hints
    }

    /**
     * Reads a lookup key back. Returns null only for a string that is neither —
     * so a caller that gets null is looking at something it did not produce,
     * rather than at a reference it should have handled.
     */
    fun key(value: String): Key? = when {
        value.startsWith(COORDINATE_PREFIX) -> parse(value)?.let { Key.Address(it) }
        isHexEventId(value) -> Key.Event(value)
        else -> null
    }

    /** Builds a coordinate string. One definition, so [parse] cannot drift from it. */
    fun format(coordinate: Coordinate): String =
        "$COORDINATE_PREFIX${coordinate.kind}:${coordinate.pubkey}:${coordinate.dTag}"

    /** Splits a coordinate string back into its parts. Null for anything else. */
    fun parse(value: String): Coordinate? {
        if (!value.startsWith(COORDINATE_PREFIX)) return null
        // limit 4 keeps a d tag containing ":" intact.
        val parts = value.split(":", limit = 4)
        if (parts.size < 3) return null
        val kind = parts[1].toIntOrNull() ?: return null
        if (parts[2].isEmpty()) return null
        return Coordinate(kind, parts[2], if (parts.size > 3) parts[3] else "")
    }

    private fun isHexEventId(value: String): Boolean =
        value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
}
