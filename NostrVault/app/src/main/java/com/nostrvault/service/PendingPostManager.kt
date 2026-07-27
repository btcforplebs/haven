package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.model.FeedNote
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Manages a 5-second countdown before publishing events.
 * Allows the user to cancel or edit before the post goes live.
 * Port of PendingPostManager.swift.
 */
@Singleton
class PendingPostManager @Inject constructor() {

    companion object {
        private const val TAG = "PendingPostManager"
        const val COUNTDOWN_DURATION_MS = 5000L
        private const val TICK_INTERVAL_MS = 100L
    }

    enum class ActionType(val label: String, val canEdit: Boolean) {
        NEW_POST("Posting", true),
        REPLY("Replying", true),
        QUOTE("Quoting", true),
        REPOST("Reposting", false),
        DELETE("Deleting", false),
    }

    data class EditRequest(
        val content: String,
        val replyTo: FeedNote?,
        val quoteTo: FeedNote?,
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private val _isShowing = MutableStateFlow(false)
    val isShowing: StateFlow<Boolean> = _isShowing.asStateFlow()

    private val _actionType = MutableStateFlow<ActionType?>(null)
    val actionType: StateFlow<ActionType?> = _actionType.asStateFlow()

    private val _timeRemaining = MutableStateFlow(0f)
    val timeRemaining: StateFlow<Float> = _timeRemaining.asStateFlow()

    private val _editRequest = MutableSharedFlow<EditRequest>(extraBufferCapacity = 1)
    val editRequest: SharedFlow<EditRequest> = _editRequest.asSharedFlow()

    private var countdownJob: Job? = null
    private var pendingContent: String = ""
    private var pendingReplyTo: FeedNote? = null
    private var pendingQuoteTo: FeedNote? = null
    private var pendingPublishAction: (() -> Unit)? = null

    fun startPost(
        event: NostrEvent,
        content: String,
        replyTo: FeedNote?,
        quoteTo: FeedNote?,
        onPublish: (NostrEvent) -> Unit,
    ) {
        val type = when {
            quoteTo != null -> ActionType.QUOTE
            replyTo != null -> ActionType.REPLY
            else -> ActionType.NEW_POST
        }
        pendingContent = content
        pendingReplyTo = replyTo
        pendingQuoteTo = quoteTo
        startCountdown(type) { onPublish(event) }
    }

    fun startRepost(onPublish: () -> Unit) {
        pendingContent = ""
        pendingReplyTo = null
        pendingQuoteTo = null
        startCountdown(ActionType.REPOST, onPublish)
    }

    fun startDelete(onDelete: () -> Unit) {
        pendingContent = ""
        pendingReplyTo = null
        pendingQuoteTo = null
        startCountdown(ActionType.DELETE, onDelete)
    }

    /**
     * Hides the countdown banner without touching the pending action — the
     * swipe gesture on the banner. The countdown job and the publish that
     * follows it keep running; this is the opposite of [cancel].
     */
    fun dismissBanner() {
        if (!_isShowing.value) return
        _isShowing.value = false
    }

    fun cancel() {
        countdownJob?.cancel()
        countdownJob = null
        pendingPublishAction = null
        _isShowing.value = false
        _actionType.value = null
        _timeRemaining.value = 0f
    }

    fun requestEdit() {
        val type = _actionType.value
        if (type?.canEdit != true) return

        countdownJob?.cancel()
        countdownJob = null
        pendingPublishAction = null
        _isShowing.value = false
        _actionType.value = null

        _editRequest.tryEmit(
            EditRequest(
                content = pendingContent,
                replyTo = pendingReplyTo,
                quoteTo = pendingQuoteTo,
            ),
        )
    }

    private fun startCountdown(type: ActionType, onComplete: () -> Unit) {
        cancel() // cancel any existing countdown
        pendingPublishAction = onComplete
        _actionType.value = type
        _timeRemaining.value = COUNTDOWN_DURATION_MS / 1000f
        _isShowing.value = true

        countdownJob = scope.launch {
            val steps = (COUNTDOWN_DURATION_MS / TICK_INTERVAL_MS).toInt()
            for (i in steps downTo 0) {
                _timeRemaining.value = (i * TICK_INTERVAL_MS) / 1000f
                if (i > 0) delay(TICK_INTERVAL_MS)
            }

            // Countdown complete — publish
            try {
                pendingPublishAction?.invoke()
            } catch (e: Exception) {
                Log.e(TAG, "Publish failed", e)
            }

            _isShowing.value = false
            _actionType.value = null
            pendingPublishAction = null
        }
    }
}
