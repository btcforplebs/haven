package com.nostrvault.ui.components

import android.util.Rational
import androidx.media3.exoplayer.ExoPlayer
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Connects the currently-playing full-screen [ExoPlayer] to MainActivity's
 * Picture-in-Picture hooks. The player composable registers itself here; the
 * activity reads [hasActiveVideo]/[aspectRatio] to build PiP params and flips
 * [isInPiP] from onPictureInPictureModeChanged so composables can hide chrome.
 */
object VideoPiPBridge {

    /** True while the activity is displayed in a PiP window. */
    val isInPiP = MutableStateFlow(false)

    private var activePlayer: ExoPlayer? = null

    var aspectRatio: Rational? = null
        private set

    /** MainActivity hook — refreshes auto-enter PiP params whenever the active video changes. */
    var onActiveVideoChanged: (() -> Unit)? = null

    val hasActiveVideo: Boolean get() = activePlayer != null

    fun setActive(player: ExoPlayer) {
        activePlayer = player
        onActiveVideoChanged?.invoke()
    }

    fun updateAspectRatio(width: Int, height: Int) {
        if (width <= 0 || height <= 0) return
        // The platform rejects PiP aspect ratios outside ~0.418–2.39 — clamp extremes.
        val ratio = (width.toFloat() / height.toFloat()).coerceIn(0.42f, 2.38f)
        aspectRatio = Rational((ratio * 10000).toInt(), 10000)
        onActiveVideoChanged?.invoke()
    }

    fun clearActive(player: ExoPlayer) {
        if (activePlayer === player) {
            activePlayer = null
            aspectRatio = null
            onActiveVideoChanged?.invoke()
        }
    }

    /** Called when the PiP window is closed (not expanded) so audio doesn't keep playing. */
    fun pauseActive() {
        activePlayer?.pause()
    }
}
