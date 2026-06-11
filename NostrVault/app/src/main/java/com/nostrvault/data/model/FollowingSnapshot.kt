package com.nostrvault.data.model

import kotlinx.serialization.Serializable

/**
 * A snapshot of the user's following list at a point in time.
 * Used for following backup/restore functionality.
 */
@Serializable
data class FollowingSnapshot(
    val id: String,
    val capturedAt: Long,
    val pubkeys: List<String>,
    val pTags: List<List<String>>,
    val contactListContent: String,
) {
    val followCount: Int get() = pubkeys.size
}

@Serializable
data class FollowingSnapshotStore(
    val snapshots: List<FollowingSnapshot>,
) {
    companion object {
        const val MAX_SNAPSHOTS = 25
    }
}
