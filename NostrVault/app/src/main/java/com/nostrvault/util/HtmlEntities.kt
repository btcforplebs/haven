package com.nostrvault.util

/**
 * Decodes the HTML character references that appear in OpenGraph metadata.
 *
 * `og:title` and `og:description` are attribute values in a real HTML page, so
 * they arrive encoded: an apostrophe is `&#39;`, an ampersand `&amp;`. Rendered
 * as-is, a link preview reads "Bob&#39;s blog". Only the entities that actually
 * turn up in page titles are named here; anything else numeric is decoded by
 * code point, and anything unrecognised is left exactly as it came so no text
 * is lost.
 *
 * `Html.fromHtml` would also do this, but it is an Android framework call and
 * would drag the OG parsing out of reach of a unit test for a two-table job.
 */
object HtmlEntities {

    private val named = mapOf(
        "amp" to "&", "lt" to "<", "gt" to ">", "quot" to "\"", "apos" to "'",
        "nbsp" to "\u00A0", "ndash" to "–", "mdash" to "—", "hellip" to "…",
        "lsquo" to "‘", "rsquo" to "’", "ldquo" to "“", "rdquo" to "”",
        "laquo" to "«", "raquo" to "»", "middot" to "·", "bull" to "•",
        "copy" to "©", "reg" to "®", "trade" to "™", "deg" to "°", "euro" to "€",
        "pound" to "£", "yen" to "¥", "cent" to "¢", "sect" to "§", "para" to "¶",
        "times" to "×", "divide" to "÷", "frac12" to "½", "frac14" to "¼",
    )

    /** Longest entity name plus the `&`, `#`, `x` and `;` around a numeric form. */
    private const val MAX_REFERENCE_LENGTH = 12

    fun decode(input: String): String {
        if (!input.contains('&')) return input

        val result = StringBuilder(input.length)
        var i = 0
        while (i < input.length) {
            val c = input[i]
            if (c != '&') {
                result.append(c)
                i++
                continue
            }

            // A reference ends at the first ";" — but an unescaped "&" in prose
            // has no ";" near it, so only look a short way ahead.
            val window = minOf(input.length, i + 1 + MAX_REFERENCE_LENGTH)
            val semicolon = input.indexOf(';', startIndex = i + 1).takeIf { it in 0 until window }
            val decoded = semicolon?.let { decodeReference(input.substring(i + 1, it)) }
            if (decoded == null) {
                // Not a reference. Emit the "&" alone and carry on from the very
                // next character — the ";" we found may belong to a real entity
                // further along ("A & B &amp; C"), and skipping to it would eat one.
                result.append('&')
                i++
            } else {
                result.append(decoded)
                i = semicolon + 1
            }
        }
        return result.toString()
    }

    private fun decodeReference(body: String): String? {
        if (body.isEmpty()) return null

        if (body[0] == '#') {
            val digits = body.substring(1)
            val code = if (digits.startsWith("x", ignoreCase = true)) {
                digits.substring(1).toIntOrNull(16)
            } else {
                digits.toIntOrNull()
            } ?: return null
            if (code !in 0..0x10FFFF || code in 0xD800..0xDFFF) return null
            return String(Character.toChars(code))
        }

        return named[body.lowercase()]
    }
}
