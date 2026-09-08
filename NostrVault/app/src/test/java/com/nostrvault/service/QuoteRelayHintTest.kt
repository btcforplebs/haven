package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * A relay hint is a URL a stranger wrote into a note, so it is reduced to
 * something worth dialling before the socket layer ever sees it.
 */
class QuoteRelayHintTest {

    private fun normalize(hint: String) = FeedService.normalizedRelayUrl(hint)

    @Test
    fun `a wss hint passes through`() {
        assertEquals("wss://relay.example.com", normalize("wss://relay.example.com"))
    }

    @Test
    fun `a trailing slash is dropped so one relay is not dialled twice`() {
        assertEquals("wss://relay.example.com", normalize("wss://relay.example.com/"))
    }

    @Test
    fun `a scheme-less hint is read as wss`() {
        // Hints are written by hand often enough that this is common.
        assertEquals("wss://relay.example.com", normalize("relay.example.com"))
    }

    @Test
    fun `an http hint is refused rather than dialled`() {
        assertNull(normalize("https://relay.example.com"))
    }

    @Test
    fun `junk is refused`() {
        assertNull(normalize(""))
        assertNull(normalize("   "))
        assertNull(normalize("wss://"))
        assertNull(normalize("not a url"))
        assertNull(normalize("localhost"))
    }
}
