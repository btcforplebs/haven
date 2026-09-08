package com.nostrvault.util

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class HtmlEntitiesTest {

    @Test
    fun `named references decode`() {
        assertEquals("Bob's blog", HtmlEntities.decode("Bob&apos;s blog"))
        assertEquals("Tom & Jerry", HtmlEntities.decode("Tom &amp; Jerry"))
        assertEquals("\"quoted\"", HtmlEntities.decode("&quot;quoted&quot;"))
    }

    @Test
    fun `decimal and hex numeric references decode`() {
        assertEquals("Bob's blog", HtmlEntities.decode("Bob&#39;s blog"))
        assertEquals("Bob's blog", HtmlEntities.decode("Bob&#x27;s blog"))
        assertEquals("Bob's blog", HtmlEntities.decode("Bob&#X27;s blog"))
    }

    @Test
    fun `a reference outside the basic plane decodes to a surrogate pair`() {
        assertEquals("🐝", HtmlEntities.decode("&#128029;"))
    }

    @Test
    fun `an unrecognised reference is left exactly as it came`() {
        assertEquals("&notanentity;", HtmlEntities.decode("&notanentity;"))
        assertEquals("&#;", HtmlEntities.decode("&#;"))
        assertEquals("&#zz;", HtmlEntities.decode("&#zz;"))
    }

    @Test
    fun `a bare ampersand does not swallow a real entity further along`() {
        // The nearest ";" belongs to &amp;, not to the bare "&". Skipping ahead
        // to it would eat the entity as well as the text between them.
        assertEquals("A & B & C", HtmlEntities.decode("A & B &amp; C"))
    }

    @Test
    fun `an unterminated reference at the end is left alone`() {
        assertEquals("ends with &amp", HtmlEntities.decode("ends with &amp"))
    }

    @Test
    fun `a semicolon far away is not treated as a terminator`() {
        val input = "&this is a long stretch of prose; really"
        assertEquals(input, HtmlEntities.decode(input))
    }

    @Test
    fun `a surrogate code point is refused rather than producing broken text`() {
        assertEquals("&#xD800;", HtmlEntities.decode("&#xD800;"))
    }

    @Test
    fun `an out-of-range code point is refused`() {
        assertEquals("&#1114112;", HtmlEntities.decode("&#1114112;"))
    }

    @Test
    fun `text with no ampersand is returned unchanged without copying`() {
        val input = "nothing to do here"
        assertSame(input, HtmlEntities.decode(input))
    }

    @Test
    fun `adjacent references both decode`() {
        assertEquals("<>", HtmlEntities.decode("&lt;&gt;"))
    }
}
