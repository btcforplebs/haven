package com.nostrvault.service

/**
 * Port of ContactManager.swift -- pure contact list management logic.
 * No networking, no UI. Operates on tag lists and pubkey sets.
 */
object ContactManager {

    sealed class FollowActionError : Exception() {
        data object ContactsNotLoaded : FollowActionError()
        data object AlreadyFollowing : FollowActionError()
        data object CannotUnfollowSelf : FollowActionError()
    }

    data class ContactListResult(
        val pTags: List<List<String>>,
        val pubkeys: List<String>,
        val relayPTagCount: Int,
    )

    data class FollowResult(
        val pTags: List<List<String>>,
        val pubkeys: List<String>,
    )

    /**
     * Parse a kind-3 contact list event's p-tags into the canonical follow set.
     * Ensures the owner and whitelisted accounts are included.
     */
    fun parseContactList(
        pTags: List<List<String>>,
        ownerHex: String,
        whitelistedNpubs: List<String>,
    ): ContactListResult {
        val relayCount = pTags.size
        val finalPTags = pTags.toMutableList()
        val existingPubkeys = pTags.mapNotNull { if (it.size >= 2) it[1] else null }.toSet()

        // Ensure owner is in the list
        if (ownerHex !in existingPubkeys) {
            finalPTags.add(listOf("p", ownerHex))
        }

        // Auto-follow whitelisted accounts
        for (npub in whitelistedNpubs) {
            // TODO: bech32 decode npub to hex
            // For now, skip bech32 conversion -- will be added when Bech32 utility is ported
        }

        val pubkeys = finalPTags.mapNotNull { if (it.size >= 2) it[1] else null }
        return ContactListResult(finalPTags, pubkeys, relayCount)
    }

    /**
     * Validate and perform a follow operation on the tag list.
     */
    fun prepareFollow(
        pubkey: String,
        currentPTags: List<List<String>>,
        currentPubkeys: List<String>,
        hasAttemptedLoad: Boolean,
        isLoading: Boolean,
    ): Result<FollowResult> {
        if (!hasAttemptedLoad || isLoading) {
            return Result.failure(FollowActionError.ContactsNotLoaded)
        }
        if (pubkey in currentPubkeys) {
            return Result.failure(FollowActionError.AlreadyFollowing)
        }
        val newPTags = currentPTags + listOf(listOf("p", pubkey))
        val newPubkeys = currentPubkeys + pubkey
        return Result.success(FollowResult(newPTags, newPubkeys))
    }

    /**
     * Validate and perform an unfollow operation on the tag list.
     */
    fun prepareUnfollow(
        pubkey: String,
        activeAccountHex: String,
        currentPTags: List<List<String>>,
        currentPubkeys: List<String>,
        hasAttemptedLoad: Boolean,
        isLoading: Boolean,
    ): Result<FollowResult> {
        if (!hasAttemptedLoad || isLoading) {
            return Result.failure(FollowActionError.ContactsNotLoaded)
        }
        if (pubkey == activeAccountHex) {
            return Result.failure(FollowActionError.CannotUnfollowSelf)
        }
        val newPTags = currentPTags.filter { !(it.size >= 2 && it[1] == pubkey) }
        val newPubkeys = currentPubkeys.filter { it != pubkey }
        return Result.success(FollowResult(newPTags, newPubkeys))
    }

    /**
     * Returns true if publishing should be BLOCKED because the contact list
     * would shrink drastically (prevents accidental wipes from stale data).
     */
    fun shouldBlockPublish(currentTagCount: Int, lastFetchedCount: Int): Boolean {
        if (lastFetchedCount <= 10) return false
        val ratio = currentTagCount.toDouble() / lastFetchedCount.toDouble()
        return ratio < 0.5
    }

    /**
     * Count mutual follows from a kind-3 event's tags, excluding the user's own follows.
     */
    fun countMutualFollows(
        eventTags: List<List<String>>,
        excludeSet: Set<String>,
    ): Map<String, Int> {
        val counts = mutableMapOf<String, Int>()
        for (tag in eventTags) {
            if (tag.size >= 2 && tag[0] == "p") {
                val pk = tag[1]
                if (pk !in excludeSet) {
                    counts[pk] = (counts[pk] ?: 0) + 1
                }
            }
        }
        return counts
    }

    /**
     * Rank pubkeys by mutual-follow count and return the top results.
     */
    fun rankExtendedNetwork(
        mutualCounts: Map<String, Int>,
        maxResults: Int = 500,
    ): List<String> =
        mutualCounts.entries
            .sortedByDescending { it.value }
            .take(maxResults)
            .map { it.key }
}
