package com.nostrvault.ui.components

import android.net.Uri
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import com.nostrvault.ui.theme.NostrVaultIcons
import kotlinx.coroutines.delay

/**
 * Full-screen video player composable wrapping Media3 ExoPlayer.
 *
 * Features:
 * - Auto-play with looping (matches iOS FullScreenVideoPlayer behaviour)
 * - Tap to toggle controls overlay
 * - Center play/pause button
 * - Bottom bar with mute toggle and progress indicator
 * - Proper lifecycle management (releases player on dispose)
 */
@OptIn(ExperimentalMaterial3Api::class)
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable
fun VideoPlayer(
    uri: String,
    modifier: Modifier = Modifier,
    autoplay: Boolean = true,
) {
    val context = LocalContext.current

    var isPlaying by remember { mutableStateOf(autoplay) }
    var isMuted by remember { mutableStateOf(false) }
    var progress by remember { mutableFloatStateOf(0f) }
    var isSeeking by remember { mutableStateOf(false) }
    var showControls by remember { mutableStateOf(true) }

    val exoPlayer = remember {
        ExoPlayer.Builder(context).build().apply {
            setMediaItem(MediaItem.fromUri(Uri.parse(uri)))
            repeatMode = Player.REPEAT_MODE_ALL
            playWhenReady = autoplay
            prepare()
        }
    }

    // Listen to player state changes and release on dispose
    DisposableEffect(exoPlayer) {
        val listener = object : Player.Listener {
            override fun onIsPlayingChanged(playing: Boolean) {
                isPlaying = playing
            }
        }
        exoPlayer.addListener(listener)
        onDispose {
            exoPlayer.removeListener(listener)
            exoPlayer.release()
        }
    }

    // Poll progress ~4 times per second while playing (skip updates during seek)
    LaunchedEffect(isPlaying, isSeeking) {
        while (isPlaying && !isSeeking) {
            val duration = exoPlayer.duration.coerceAtLeast(1L)
            progress = exoPlayer.currentPosition.toFloat() / duration.toFloat()
            delay(250)
        }
    }

    // Auto-hide controls after 3 seconds
    LaunchedEffect(showControls) {
        if (showControls && isPlaying) {
            delay(3000)
            showControls = false
        }
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(Color.Black)
            .clickable(
                indication = null,
                interactionSource = remember { MutableInteractionSource() },
            ) { showControls = !showControls },
    ) {
        // Video surface
        AndroidView(
            factory = { ctx ->
                PlayerView(ctx).apply {
                    player = exoPlayer
                    useController = false
                    setShowBuffering(PlayerView.SHOW_BUFFERING_WHEN_PLAYING)
                }
            },
            modifier = Modifier.fillMaxSize(),
        )

        // Controls overlay
        AnimatedVisibility(
            visible = showControls,
            enter = fadeIn(),
            exit = fadeOut(),
            modifier = Modifier.fillMaxSize(),
        ) {
            Box(modifier = Modifier.fillMaxSize()) {
                // Center play/pause
                IconButton(
                    onClick = {
                        if (exoPlayer.isPlaying) exoPlayer.pause() else exoPlayer.play()
                    },
                    modifier = Modifier
                        .align(Alignment.Center)
                        .size(64.dp)
                        .background(
                            color = Color.Black.copy(alpha = 0.4f),
                            shape = CircleShape,
                        ),
                ) {
                    Icon(
                        imageVector = if (isPlaying) NostrVaultIcons.PauseIcon
                                      else NostrVaultIcons.PlayArrow,
                        contentDescription = if (isPlaying) "Pause" else "Play",
                        tint = Color.White,
                        modifier = Modifier.size(36.dp),
                    )
                }

                // Bottom bar: mute toggle + progress
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth()
                        .navigationBarsPadding()
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                ) {
                    IconButton(
                        onClick = {
                            isMuted = !isMuted
                            exoPlayer.volume = if (isMuted) 0f else 1f
                        },
                        modifier = Modifier.size(40.dp),
                    ) {
                        Icon(
                            imageVector = if (isMuted) NostrVaultIcons.VolumeOff
                                          else NostrVaultIcons.VolumeUp,
                            contentDescription = if (isMuted) "Unmute" else "Mute",
                            tint = Color.White,
                        )
                    }

                    Slider(
                        value = progress,
                        onValueChange = { newProgress ->
                            isSeeking = true
                            progress = newProgress
                            val duration = exoPlayer.duration.coerceAtLeast(1L)
                            exoPlayer.seekTo((newProgress * duration).toLong())
                        },
                        onValueChangeFinished = {
                            isSeeking = false
                        },
                        modifier = Modifier
                            .weight(1f)
                            .height(20.dp)
                            .padding(horizontal = 8.dp),
                        colors = SliderDefaults.colors(
                            thumbColor = Color.White,
                            activeTrackColor = Color.White,
                            inactiveTrackColor = Color.White.copy(alpha = 0.3f),
                        ),
                        thumb = {
                            Box(
                                modifier = Modifier
                                    .size(width = 5.dp, height = 14.dp)
                                    .background(Color.White, RoundedCornerShape(2.5.dp)),
                            )
                        },
                    )
                }
            }
        }
    }
}
