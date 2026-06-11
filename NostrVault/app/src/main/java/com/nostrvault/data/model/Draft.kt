package com.nostrvault.data.model

import kotlinx.serialization.Serializable
import java.util.UUID

/**
 * A locally saved draft of a note being composed.
 * Synced to the local relay as kind 31234 (parameterized replaceable event)
 * on the /private endpoint.
 */
@Serializable
data class Draft(
    val id: String = UUID.randomUUID().toString(),
    val content: String,
    val pubkey: String = "",
    val replyToId: String? = null,
    val rootId: String? = null,
    val quoteId: String? = null,
    val quotePubkey: String? = null,
    val tags: List<List<String>> = emptyList(),
    val updatedAt: Long = System.currentTimeMillis(),
) {
    val preview: String
        get() = content.take(80).replace('\n', ' ')

    val isReply: Boolean
        get() = replyToId != null

    val isQuote: Boolean
        get() = quoteId != null
}

@Serializable
data class DraftStore(
    val drafts: List<Draft> = emptyList(),
)
