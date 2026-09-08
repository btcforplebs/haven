package com.nostrvault.fips

import android.util.Log
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * JNI bridge to the FIPS mesh endpoint (libfips_bridge_ffi.so, Rust).
 *
 * The same C ABI the Mac and iOS sides link against; see
 * fips-bridge/crates/fips-bridge-ffi. Control plane only — the data plane
 * (QUIC, the FIPS pump) never crosses this boundary, because video at 8 Mbps is
 * ~830 datagrams/sec each way and a Java array per packet would be GC pressure
 * for no reason.
 *
 * Unlike libhaven.so, the Rust library is optional: it does not cross-compile
 * for armeabi-v7a (see build_fips_android.sh) and a checkout without it still
 * builds. [isAvailable] is false in that case and every call is a no-op, so the
 * UI can say so plainly rather than crashing.
 */
object FipsBridge {

    private const val TAG = "FipsBridge"

    /** False when this build has no libfips_bridge_ffi.so for the device's ABI. */
    @Volatile
    var isAvailable: Boolean = false
        private set

    private val json = Json { ignoreUnknownKeys = true }

    init {
        try {
            System.loadLibrary("fips_bridge_ffi")
            System.loadLibrary("fips-bridge-jni")
            isAvailable = true
            Log.i(TAG, "libfips_bridge_ffi.so + libfips-bridge-jni.so loaded")
        } catch (e: UnsatisfiedLinkError) {
            isAvailable = false
            Log.w(TAG, "FIPS mesh unavailable in this build: ${e.message}")
        }
    }

    /**
     * Bind the endpoint under [nsec] and stand up QUIC over it.
     *
     * Pass the *same* nsec every launch: the npub derived from it is the
     * address peers use, so a fresh key each start makes you unfindable by
     * anyone who saw you before. Returns 0 on success, negative on failure,
     * and is idempotent — starting an already-running bridge returns 0.
     */
    fun start(nsec: String): Int =
        if (!isAvailable) ERR_UNAVAILABLE else nativeStart(nsec)

    /** A fresh network identity to persist. Null if the library is absent. */
    fun generateNsec(): String? =
        if (!isAvailable) null else nativeGenerateNsec()

    /** Current state. Never null; reports [FipsStatus.stopped] when unavailable. */
    fun status(): FipsStatus {
        if (!isAvailable) return FipsStatus.stopped
        val raw = nativeStatusJSON() ?: return FipsStatus.stopped
        return try {
            json.decodeFromString<FipsStatus>(raw)
        } catch (e: Exception) {
            Log.w(TAG, "unparseable status: $raw")
            FipsStatus.stopped
        }
    }

    /** Export a local TCP port to the mesh. 0 on success, negative on failure. */
    fun export(localPort: Int): Int =
        if (!isAvailable) ERR_UNAVAILABLE else nativeExport(localPort)

    /**
     * Open a loopback listener proxying to [npub] over the mesh. Returns the
     * bound port, or negative on failure.
     */
    fun ingress(npub: String): Int =
        if (!isAvailable) ERR_UNAVAILABLE else nativeIngress(npub)

    fun stop() {
        if (isAvailable) nativeStop()
    }

    /** Distinct from the Rust side's own negatives, which run -1..-99. */
    const val ERR_UNAVAILABLE = -100

    private external fun nativeStart(nsec: String): Int
    private external fun nativeGenerateNsec(): String?
    private external fun nativeStatusJSON(): String?
    private external fun nativeExport(localPort: Int): Int
    private external fun nativeIngress(npub: String): Int
    private external fun nativeStop()
}

/**
 * Snapshot of the bridge, as the C ABI serialises it.
 *
 * `npub` and `address` are absent while stopped — the Rust side emits
 * `{"running":false}` and nothing else — so they are nullable here rather than
 * defaulted to a blank string that would render as an empty address.
 */
@Serializable
data class FipsStatus(
    val running: Boolean = false,
    val npub: String? = null,
    val address: String? = null,
    @SerialName("uptime_s") val uptimeSeconds: Long = 0,
) {
    companion object {
        val stopped = FipsStatus()
    }
}
