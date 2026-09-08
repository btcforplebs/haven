package com.nostrvault.fips

import com.nostrvault.ui.screens.settings.formatUptime
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The payload strings here are copied verbatim from the format! calls in
 * fips-bridge/crates/fips-bridge-ffi/src/lib.rs (FipsBridgeStatusJSON). If that
 * function's shape changes, these fail — which is the point: nothing else on
 * this side of the FFI can notice a field that quietly stopped arriving.
 */
class FipsStatusTest {

    private val json = Json { ignoreUnknownKeys = true }

    @Test fun `a stopped bridge sends running and nothing else`() {
        val status = json.decodeFromString<FipsStatus>("""{"running":false}""")

        assertFalse(status.running)
        // Null, not "". A blank string would render as an address the user
        // could select and copy, and they would copy nothing.
        assertNull(status.npub)
        assertNull(status.address)
        assertEquals(0L, status.uptimeSeconds)
    }

    @Test fun `a running bridge carries the address peers dial`() {
        val status = json.decodeFromString<FipsStatus>(
            """{"running":true,"npub":"npub1exampleexampleexample","address":"fd00::1","uptime_s":93}"""
        )

        assertTrue(status.running)
        assertEquals("npub1exampleexampleexample", status.npub)
        assertEquals("fd00::1", status.address)
        // snake_case on the wire, camelCase in Kotlin: without the SerialName
        // this decodes to 0 and the screen reads "Up 0s" forever.
        assertEquals(93L, status.uptimeSeconds)
    }

    @Test fun `an unknown field does not throw away the whole snapshot`() {
        // The Rust side may add counters; a strict parser would turn that into
        // "bridge stopped" on a bridge that is running.
        val status = json.decodeFromString<FipsStatus>(
            """{"running":true,"npub":"npub1x","address":"fd00::2","uptime_s":1,"peers":3}"""
        )

        assertTrue(status.running)
        assertEquals("npub1x", status.npub)
        assertEquals(1L, status.uptimeSeconds)
    }

    @Test fun `uptime reads as a duration, not a number of seconds`() {
        assertEquals("45s", formatUptime(45))
        assertEquals("1m 5s", formatUptime(65))
        assertEquals("2h 1m", formatUptime(7260))
    }

    /**
     * The build ships no mesh library for 32-bit ARM (nvpn-fips-core 0.4.72
     * does not compile for it), and CMake leaves the JNI shim out of any
     * checkout without the Rust artifact. Both cases land here: on the JVM
     * there is no libfips_bridge_ffi.so either, so this exercises the real
     * unavailable path rather than a mock of it.
     */
    @Test fun `every call is safe when the library is absent`() {
        assertFalse(FipsBridge.isAvailable)

        assertEquals(FipsBridge.ERR_UNAVAILABLE, FipsBridge.start("nsec1whatever"))
        assertEquals(FipsBridge.ERR_UNAVAILABLE, FipsBridge.export(8080))
        assertEquals(FipsBridge.ERR_UNAVAILABLE, FipsBridge.ingress("npub1whatever"))
        assertNull(FipsBridge.generateNsec())
        assertEquals(FipsStatus.stopped, FipsBridge.status())
        FipsBridge.stop()
    }
}
