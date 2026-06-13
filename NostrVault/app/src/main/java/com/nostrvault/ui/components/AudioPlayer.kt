package com.nostrvault.ui.components

import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.FastForward
import androidx.compose.material.icons.filled.FastRewind
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import kotlinx.coroutines.delay

/**
 * Audio player composable (ExoPlayer audio + custom controls) — port of iOS
 * AudioPlayerView: waveform icon, filename, scrub bar with time labels,
 * play/pause and ±15s skip. Replaces the black video surface for audio blobs.
 */
@Composable
fun AudioPlayer(
    uri: String,
    fileName: String,
    modifier: Modifier = Modifier,
    autoplay: Boolean = true,
) {
    val context = LocalContext.current
    val accent = LocalNostrVaultColors.current.primary

    var isPlaying by remember { mutableStateOf(autoplay) }
    var positionMs by remember { mutableLongStateOf(0L) }
    var durationMs by remember { mutableLongStateOf(0L) }
    var isSeeking by remember { mutableStateOf(false) }

    val exoPlayer = remember {
        ExoPlayer.Builder(context).build().apply {
            setMediaItem(MediaItem.fromUri(Uri.parse(uri)))
            playWhenReady = autoplay
            prepare()
        }
    }

    DisposableEffect(exoPlayer) {
        val listener = object : Player.Listener {
            override fun onIsPlayingChanged(playing: Boolean) { isPlaying = playing }
            override fun onPlaybackStateChanged(state: Int) {
                if (state == Player.STATE_READY) durationMs = exoPlayer.duration.coerceAtLeast(0L)
            }
        }
        exoPlayer.addListener(listener)
        onDispose {
            exoPlayer.removeListener(listener)
            exoPlayer.release()
        }
    }

    LaunchedEffect(isPlaying, isSeeking) {
        while (isPlaying && !isSeeking) {
            positionMs = exoPlayer.currentPosition
            if (durationMs <= 0L) durationMs = exoPlayer.duration.coerceAtLeast(0L)
            delay(250)
        }
    }

    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .fillMaxSize()
            .background(Color.Black),
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(20.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 32.dp),
        ) {
            Icon(
                imageVector = Icons.Filled.GraphicEq,
                contentDescription = "Audio",
                tint = accent,
                modifier = Modifier.size(120.dp),
            )

            Text(
                text = fileName,
                color = Color.White,
                fontSize = 16.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center,
            )

            Column(modifier = Modifier.fillMaxWidth()) {
                val safeDuration = durationMs.coerceAtLeast(1L)
                Slider(
                    value = positionMs.toFloat().coerceIn(0f, safeDuration.toFloat()),
                    valueRange = 0f..safeDuration.toFloat(),
                    onValueChange = {
                        isSeeking = true
                        positionMs = it.toLong()
                    },
                    onValueChangeFinished = {
                        exoPlayer.seekTo(positionMs)
                        isSeeking = false
                    },
                    colors = SliderDefaults.colors(
                        thumbColor = accent,
                        activeTrackColor = accent,
                        inactiveTrackColor = Color.White.copy(alpha = 0.3f),
                    ),
                )
                Row(modifier = Modifier.fillMaxWidth()) {
                    Text(formatTime(positionMs), color = Color.White.copy(alpha = 0.7f),
                        fontSize = 12.sp, fontFamily = FontFamily.Monospace)
                    Spacer(Modifier.weight(1f))
                    Text(formatTime(durationMs), color = Color.White.copy(alpha = 0.7f),
                        fontSize = 12.sp, fontFamily = FontFamily.Monospace)
                }
            }

            Row(
                horizontalArrangement = Arrangement.spacedBy(28.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = {
                    val target = (exoPlayer.currentPosition - 15_000).coerceAtLeast(0L)
                    exoPlayer.seekTo(target)
                    positionMs = target
                }) {
                    Icon(Icons.Filled.FastRewind, contentDescription = "Back 15s",
                        tint = Color.White, modifier = Modifier.size(30.dp))
                }

                IconButton(
                    onClick = { if (exoPlayer.isPlaying) exoPlayer.pause() else exoPlayer.play() },
                    modifier = Modifier
                        .size(64.dp)
                        .background(accent.copy(alpha = 0.2f), CircleShape),
                ) {
                    Icon(
                        imageVector = if (isPlaying) NostrVaultIcons.PauseIcon else NostrVaultIcons.PlayArrow,
                        contentDescription = if (isPlaying) "Pause" else "Play",
                        tint = accent,
                        modifier = Modifier.size(40.dp),
                    )
                }

                IconButton(onClick = {
                    val dur = exoPlayer.duration.coerceAtLeast(0L)
                    val target = (exoPlayer.currentPosition + 15_000).coerceAtMost(dur)
                    exoPlayer.seekTo(target)
                    positionMs = target
                }) {
                    Icon(Icons.Filled.FastForward, contentDescription = "Forward 15s",
                        tint = Color.White, modifier = Modifier.size(30.dp))
                }
            }
        }
    }
}

private fun formatTime(ms: Long): String {
    if (ms <= 0L) return "0:00"
    val totalSec = ms / 1000
    return "%d:%02d".format(totalSec / 60, totalSec % 60)
}
