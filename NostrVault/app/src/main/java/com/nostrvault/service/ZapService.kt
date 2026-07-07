package com.nostrvault.service

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/**
 * NIP-57 zap receipt parsing.
 * Extracts zap amounts and metadata from kind-9735 events.
 */
object ZapService {

    private val json = Json { ignoreUnknownKeys = true }

    data class ZapReceipt(
        val id: String,
        val receiptPubkey: String,
        val senderPubkey: String,
        val recipientPubkey: String,
        val amountSats: Long,
        val content: String,
        val createdAt: Long,
        val targetEventId: String?,
    )

    /**
     * Parse a kind-9735 zap receipt event.
     * Extracts the bolt11 invoice amount from the "bolt11" tag
     * and sender pubkey from the embedded kind-9734 zap request in the "description" tag.
     */
    fun parseZapReceipt(
        id: String,
        pubkey: String,
        content: String,
        tags: List<List<String>>,
        createdAt: Long,
    ): ZapReceipt? {
        // Extract recipient from p-tag
        val recipientPubkey = tags.firstOrNull { it.size >= 2 && it[0] == "p" }?.get(1)
            ?: return null

        // Extract target event from e-tag
        val targetEventId = tags.firstOrNull { it.size >= 2 && it[0] == "e" }?.get(1)

        // Extract bolt11 invoice
        val bolt11 = tags.firstOrNull { it.size >= 2 && it[0] == "bolt11" }?.get(1)

        // Extract amount from bolt11 (millisat encoding in the invoice)
        val amountSats = bolt11?.let { parseBolt11Amount(it) } ?: 0L

        // Extract sender pubkey from the zap request (description tag)
        val description = tags.firstOrNull { it.size >= 2 && it[0] == "description" }?.get(1)
        val senderPubkey = description?.let { parseZapRequestSender(it) } ?: pubkey

        // Extract zap message from the zap request content
        val zapMessage = description?.let { parseZapRequestContent(it) } ?: content

        return ZapReceipt(
            id = id,
            receiptPubkey = pubkey,
            senderPubkey = senderPubkey,
            recipientPubkey = recipientPubkey,
            amountSats = amountSats,
            content = zapMessage,
            createdAt = createdAt,
            targetEventId = targetEventId,
        )
    }

    /**
     * Parse the amount from a BOLT-11 lightning invoice string.
     * Format: lnbc{amount}{multiplier}...
     */
    private fun parseBolt11Amount(bolt11: String): Long {
        val lower = bolt11.lowercase()
        if (!lower.startsWith("lnbc")) return 0L

        val amountPart = lower.removePrefix("lnbc")
        // Find where the amount ends (first non-digit, non-dot character that's a multiplier)
        val regex = Regex("""^(\d+)([munp]?)""")
        val match = regex.find(amountPart) ?: return 0L

        val amount = match.groupValues[1].toLongOrNull() ?: return 0L
        val multiplier = match.groupValues[2]

        // Convert to satoshis (BOLT-11 amounts are in BTC with multiplier suffixes)
        return when (multiplier) {
            "m" -> amount * 100_000       // milli-BTC -> sats
            "u" -> amount * 100           // micro-BTC -> sats
            "n" -> amount / 10            // nano-BTC -> sats
            "p" -> amount / 10_000        // pico-BTC -> sats
            "" -> amount * 100_000_000    // BTC -> sats
            else -> 0L
        }
    }

    private fun parseZapRequestSender(description: String): String? = try {
        val zapRequest = json.parseToJsonElement(description).jsonObject
        zapRequest["pubkey"]?.jsonPrimitive?.contentOrNull
    } catch (_: Exception) {
        null
    }

    private fun parseZapRequestContent(description: String): String? = try {
        val zapRequest = json.parseToJsonElement(description).jsonObject
        zapRequest["content"]?.jsonPrimitive?.contentOrNull
    } catch (_: Exception) {
        null
    }
}
