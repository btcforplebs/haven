package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import com.nostrvault.data.model.LiveStream
import com.nostrvault.ui.theme.*

/**
 * Player for one NIP-53 live stream.
 *
 * The stream is passed in rather than looked up by id: a kind-30311 event is
 * replaceable and short-lived, so the copy the grid was showing when the user
 * tapped is the one to play. Re-resolving could open a different broadcast, or
 * none.
 */
@OptIn(ExperimentalMaterial3Api::class)
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable
fun LiveStreamScreen(
    stream: LiveStream?,
    hostName: String?,
    onBack: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current

    val player = remember(stream?.streamingUrl) {
        val url = stream?.streamingUrl ?: return@remember null
        ExoPlayer.Builder(context).build().apply {
            setMediaItem(MediaItem.fromUri(url))
            prepare()
            playWhenReady = true
        }
    }
    // A player left running behind a closed screen keeps the socket and the
    // audio session; releasing on dispose is not optional.
    DisposableEffect(player) { onDispose { player?.release() } }

    Scaffold(
        containerColor = WindowBackground,
        topBar = {
            TopAppBar(
                title = { Text("Live", color = PrimaryText, fontSize = 17.sp) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back", tint = colors.primary)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = WindowBackground),
            )
        },
    ) { padding ->
        if (stream == null || player == null) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.fillMaxSize().padding(padding),
            ) {
                Text(
                    "That stream is no longer listed. Live events expire — go back and refresh.",
                    color = SecondaryText,
                    fontSize = 14.sp,
                )
            }
            return@Scaffold
        }

        Column(modifier = Modifier.padding(padding)) {
            AndroidView(
                factory = { ctx ->
                    PlayerView(ctx).apply {
                        this.player = player
                        useController = true
                    }
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(16f / 9f)
                    .background(Color.Black),
            )
            Column(
                modifier = Modifier
                    .verticalScroll(rememberScrollState())
                    .padding(16.dp),
            ) {
                Text(
                    text = stream.title ?: "Untitled stream",
                    color = PrimaryText,
                    fontSize = 19.sp,
                    fontWeight = FontWeight.Bold,
                    lineHeight = 25.sp,
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    text = buildString {
                        append(hostName ?: stream.hostPubkey.take(8))
                        stream.participants?.let { append(" · $it watching") }
                    },
                    color = SecondaryText,
                    fontSize = 13.sp,
                )
                stream.summary?.let {
                    Spacer(Modifier.height(12.dp))
                    Text(it, color = SecondaryText, fontSize = 14.sp, lineHeight = 20.sp)
                }
            }
        }
    }
}
