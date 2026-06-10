package com.nostrvault.service

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

/**
 * LNURL protocol service.
 * Resolves Lightning Addresses (LUD-16) and raw LNURLs (LUD-06)
 * to fetch payment invoices with optional Nostr zap support.
 *
 * Port of LNURLService.swift.
 */
object LNURLService {

    private const val TAG = "LNURLService"

    private val json = Json { ignoreUnknownKeys = true }
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    // ══════════════════════════════════════════════════════════════════
    // Address resolution
    // ══════════════════════════════════════════════════════════════════

    /**
     * Resolve a Lightning Address (user@domain.com) to LNURL pay response.
     * LUD-16: https://domain.com/.well-known/lnurlp/user
     */
    suspend fun resolveAddress(lud16: String): LNURLPayResponse = withContext(Dispatchers.IO) {
        val parts = lud16.lowercase().split("@")
        if (parts.size != 2) throw LNURLError.InvalidAddress

        val username = URLEncoder.encode(parts[0], "UTF-8")
        val domain = parts[1]
        val url = "https://$domain/.well-known/lnurlp/$username"

        fetchPayResponse(url)
    }

    /**
     * Resolve a raw LNURL (bech32-encoded) to LNURL pay response.
     * LUD-06: Decode bech32 to get HTTPS URL.
     */
    suspend fun resolveRawLNURL(lnurl: String): LNURLPayResponse = withContext(Dispatchers.IO) {
        val cleaned = lnurl.removePrefix("lnurl:").removePrefix("LNURL:")
        val decoded = Bech32.decodeLNURL(cleaned)
            ?: throw LNURLError.InvalidAddress

        fetchPayResponse(decoded)
    }

    // ══════════════════════════════════════════════════════════════════
    // Invoice fetching
    // ══════════════════════════════════════════════════════════════════

    /**
     * Fetch a Lightning invoice from a LNURL callback.
     * @param callback The callback URL from LNURLPayResponse
     * @param amountMsat Amount in millisatoshis
     * @param zapRequest Optional NIP-57 zap request event JSON
     * @return BOLT11 invoice string
     */
    suspend fun fetchInvoice(
        callback: String,
        amountMsat: Long,
        zapRequest: String? = null,
    ): String = withContext(Dispatchers.IO) {
        val urlBuilder = StringBuilder(callback)
        urlBuilder.append(if (callback.contains("?")) "&" else "?")
        urlBuilder.append("amount=$amountMsat")

        zapRequest?.let { zap ->
            val encoded = URLEncoder.encode(zap, "UTF-8")
            urlBuilder.append("&nostr=$encoded")
        }

        val request = Request.Builder()
            .url(urlBuilder.toString())
            .get()
            .build()

        val response = client.newCall(request).execute()
        if (!response.isSuccessful) {
            throw LNURLError.NetworkError("HTTP ${response.code}")
        }

        val body = response.body?.string() ?: throw LNURLError.InvalidResponse
        val parsed = json.decodeFromString<LNURLCallbackResponse>(body)
        parsed.pr ?: throw LNURLError.InvalidInvoice
    }

    // ══════════════════════════════════════════════════════════════════
    // Internal
    // ══════════════════════════════════════════════════════════════════

    private fun fetchPayResponse(url: String): LNURLPayResponse {
        Log.d(TAG, "Fetching LNURL pay response from $url")

        val request = Request.Builder()
            .url(url)
            .get()
            .build()

        val response = client.newCall(request).execute()
        if (!response.isSuccessful) {
            throw LNURLError.NetworkError("HTTP ${response.code}")
        }

        val body = response.body?.string() ?: throw LNURLError.InvalidResponse
        return json.decodeFromString<LNURLPayResponse>(body)
    }
}

// ── Data models ───────────────────────────────────────────────────

@Serializable
data class LNURLPayResponse(
    val callback: String,
    val maxSendable: Long,
    val minSendable: Long,
    val metadata: String,
    val tag: String,
    val nostrPubkey: String? = null,
    val allowsNostr: Boolean? = null,
)

@Serializable
data class LNURLCallbackResponse(
    val pr: String? = null,
    val routes: List<Map<String, String>>? = null,
)

sealed class LNURLError : Exception() {
    data object InvalidAddress : LNURLError()
    data class NetworkError(override val message: String) : LNURLError()
    data object InvalidResponse : LNURLError()
    data object InvalidInvoice : LNURLError()
}

/**
 * Minimal Bech32 LNURL decoder.
 */
object Bech32 {
    private const val CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

    fun decodeLNURL(lnurl: String): String? {
        return try {
            val lower = lnurl.lowercase()
            val pos = lower.lastIndexOf("1")
            if (pos < 1) return null

            val data = lower.substring(pos + 1).dropLast(6) // Remove checksum
            val decoded = data.map { CHARSET.indexOf(it) }.filter { it >= 0 }

            // Convert 5-bit groups to 8-bit bytes
            val bytes = convertBits(decoded, 5, 8, false) ?: return null
            String(bytes.toByteArray(), Charsets.UTF_8)
        } catch (e: Exception) {
            Log.w("Bech32", "LNURL decode failed: ${e.message}")
            null
        }
    }

    private fun convertBits(data: List<Int>, fromBits: Int, toBits: Int, pad: Boolean): List<Byte>? {
        var acc = 0
        var bits = 0
        val result = mutableListOf<Byte>()
        val maxv = (1 shl toBits) - 1

        for (value in data) {
            if (value < 0 || value >= (1 shl fromBits)) return null
            acc = (acc shl fromBits) or value
            bits += fromBits
            while (bits >= toBits) {
                bits -= toBits
                result.add(((acc shr bits) and maxv).toByte())
            }
        }

        if (pad && bits > 0) {
            result.add(((acc shl (toBits - bits)) and maxv).toByte())
        } else if (bits >= fromBits || ((acc shl (toBits - bits)) and maxv) != 0) {
            return null
        }

        return result
    }
}
