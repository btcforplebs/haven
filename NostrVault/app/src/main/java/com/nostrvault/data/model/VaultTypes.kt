package com.nostrvault.data.model

/**
 * Type definitions for the Vault / Relay tab, mirroring iOS VaultTypes.swift.
 */

enum class VaultViewMode(val displayName: String) {
    NOTES("Notes"),
    LIKES("Likes"),
    ZAPS("Zaps"),
}

enum class VaultContentFilter(val displayName: String) {
    ALL("All"),
    MINE("My Notes"),
    TAGGED("Tagged"),
    WHITELIST("Whitelisted"),
}

enum class VaultLikesFilter(val displayName: String) {
    ON_MY_NOTES("My Notes"),
    ON_TAGGED("Tagged"),
    ON_WHITELISTED("Whitelisted"),
    MY_LIKES("My Likes"),
}

enum class VaultZapsFilter(val displayName: String) {
    ON_MY_NOTES("My Notes"),
    ON_TAGGED("Tagged"),
    ON_WHITELISTED("Whitelisted"),
    MY_ZAPS("My Zaps"),
}

data class ParsedZapReceipt(
    val senderPubkey: String,
    val targetNoteId: String?,
    val amountSats: Long,
)
