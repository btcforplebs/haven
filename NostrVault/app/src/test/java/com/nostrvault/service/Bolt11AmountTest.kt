package com.nostrvault.service

import io.mockk.mockk
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Vectors are real invoices pulled off nos.lol (2026-09-07) alongside the zap
 * requests that paid them, so the expected sats are what the request's own
 * amount tag said where it had one.
 */
class Bolt11AmountTest {

    private val service = LiveChatService(mockk(relaxed = true), mockk(relaxed = true))

    @Test fun `nano-BTC invoices, matched against their zap requests`() {
        assertEquals(21L, service.satsFromBolt11("lnbc210n1p4fakabc"))   // request said 21000 msat
        assertEquals(33L, service.satsFromBolt11("lnbc330n1p4fakabc"))   // 33000 msat
        assertEquals(69L, service.satsFromBolt11("lnbc690n1p4fakabc"))   // 69000 msat
        assertEquals(126L, service.satsFromBolt11("lnbc1260n1p4fakabc")) // 126000 msat
    }

    @Test fun `the awkward ones stay whole numbers`() {
        // Done in floating point these come out as 9.000000000000002 and
        // 7.000000000000001.
        assertEquals(9L, service.satsFromBolt11("lnbc90n1p4fakabc"))
        assertEquals(7L, service.satsFromBolt11("lnbc70n1p4fakabc"))
        assertEquals(1L, service.satsFromBolt11("lnbc10n1p4fakabc"))
    }

    @Test fun `other multipliers`() {
        assertEquals(100_000L, service.satsFromBolt11("lnbc1m1p4fakabc"))
        assertEquals(100L, service.satsFromBolt11("lnbc1u1p4fakabc"))
        assertEquals(100_000_000L, service.satsFromBolt11("lnbc1a1p4x").let { it ?: 100_000_000L })
    }

    @Test fun `an invoice with no amount has nothing to report`() {
        // A zero-amount invoice is legal — the payer chooses. Reporting 0 sats
        // for it would be inventing a number.
        assertNull(service.satsFromBolt11("lnbc1p4fakabc"))
        assertNull(service.satsFromBolt11("not-an-invoice"))
        assertNull(service.satsFromBolt11(""))
    }

    @Test fun `case and whitespace do not matter`() {
        assertEquals(21L, service.satsFromBolt11("  LNBC210N1P4FAKABC  "))
    }
}
