package com.nostrvault.service

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Bitcoin price service -- fetches BTC/fiat exchange rates.
 */
@Singleton
class PriceService @Inject constructor() {

    companion object {
        private const val TAG = "PriceService"
        private const val COINGECKO_URL =
            "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd"
        private const val REFRESH_INTERVAL_MS = 5 * 60 * 1000L // 5 minutes
    }

    private val json = Json { ignoreUnknownKeys = true }
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    private val _btcPriceUsd = MutableStateFlow(0.0)
    val btcPriceUsd: StateFlow<Double> = _btcPriceUsd.asStateFlow()

    private var lastFetchTime = 0L

    /** Fetch current BTC/USD price. Caches for 5 minutes. */
    suspend fun refreshPrice() = withContext(Dispatchers.IO) {
        val now = System.currentTimeMillis()
        if (now - lastFetchTime < REFRESH_INTERVAL_MS && _btcPriceUsd.value > 0) return@withContext

        try {
            val request = Request.Builder().url(COINGECKO_URL).build()
            val response = client.newCall(request).execute()
            if (response.isSuccessful) {
                val body = response.body?.string() ?: return@withContext
                val parsed = json.parseToJsonElement(body).jsonObject
                val price = parsed["bitcoin"]?.jsonObject?.get("usd")?.jsonPrimitive?.doubleOrNull
                if (price != null && price > 0) {
                    _btcPriceUsd.value = price
                    lastFetchTime = now
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Price fetch failed: ${e.message}")
        }
    }

    /** Convert satoshis to fiat string. */
    fun satsToFiat(sats: Long): String {
        val price = _btcPriceUsd.value
        if (price <= 0) return ""
        val fiat = sats.toDouble() / 100_000_000.0 * price
        return "%.2f".format(fiat)
    }
}
