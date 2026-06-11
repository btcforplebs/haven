package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.service.BlobDescriptor
import com.nostrvault.service.StatsService
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.launch

private val ImageColor = Color(0xFF5E5CE6)
private val VideoColor = Color(0xFFFF375F)
private val AudioColor = Color(0xFFFF9F0A)
private val OtherColor = Color(0xFF64D2FF)

private data class BlobBucket(
    val label: String,
    val count: Int,
    val size: Long,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BlossomBreakdownSheet(
    statsService: StatsService,
    ownerPubkey: String,
    onDismiss: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val scope = rememberCoroutineScope()
    var blobs by remember { mutableStateOf<List<BlobDescriptor>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }

    LaunchedEffect(Unit) {
        blobs = statsService.fetchBlobList(ownerPubkey)
        isLoading = false
    }

    val buckets = remember(blobs) {
        val images = blobs.filter { it.type?.startsWith("image/") == true }
        val videos = blobs.filter { it.type?.startsWith("video/") == true }
        val audio = blobs.filter { it.type?.startsWith("audio/") == true }
        val other = blobs.filter {
            val t = it.type ?: ""
            !t.startsWith("image/") && !t.startsWith("video/") && !t.startsWith("audio/")
        }
        listOf(
            BlobBucket("Images", images.size, images.sumOf { it.size ?: 0L }),
            BlobBucket("Videos", videos.size, videos.sumOf { it.size ?: 0L }),
            BlobBucket("Audio", audio.size, audio.sumOf { it.size ?: 0L }),
            BlobBucket("Other", other.size, other.sumOf { it.size ?: 0L }),
        )
    }
    val totalSize = buckets.sumOf { it.size }

    val bucketColors = listOf(ImageColor, VideoColor, AudioColor, OtherColor)
    val bucketIcons = listOf(NostrVaultIcons.Media, NostrVaultIcons.Video, NostrVaultIcons.VolumeUp, NostrVaultIcons.Document)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = WindowBackground,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 32.dp),
        ) {
            // Header
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(bottom = 16.dp),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "Blossom Storage",
                        color = PrimaryText,
                        fontSize = 18.sp,
                        fontWeight = FontWeight.Bold,
                    )
                    Text(
                        text = "${blobs.size} files, ${formatSize(totalSize)}",
                        color = SecondaryText,
                        fontSize = 13.sp,
                    )
                }
                IconButton(
                    onClick = {
                        isLoading = true
                        scope.launch {
                            blobs = statsService.fetchBlobList(ownerPubkey)
                            isLoading = false
                        }
                    },
                    modifier = Modifier.size(32.dp),
                ) {
                    Icon(NostrVaultIcons.Refresh, "Refresh", tint = SecondaryText, modifier = Modifier.size(18.dp))
                }
            }

            if (isLoading) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier.fillMaxWidth().padding(32.dp),
                ) {
                    CircularProgressIndicator(color = colors.primary)
                }
            } else {
                Surface(
                    color = SecondaryGroupedBg,
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        buckets.forEachIndexed { index, bucket ->
                            if (bucket.count > 0) {
                                BlobTypeRow(
                                    label = bucket.label,
                                    icon = bucketIcons[index],
                                    color = bucketColors[index],
                                    count = bucket.count,
                                    size = bucket.size,
                                    total = totalSize,
                                )
                                if (index < buckets.size - 1) {
                                    HorizontalDivider(
                                        color = TertiaryText.copy(alpha = 0.2f),
                                        modifier = Modifier.padding(vertical = 4.dp),
                                    )
                                }
                            }
                        }
                        if (buckets.all { it.count == 0 }) {
                            Box(
                                contentAlignment = Alignment.Center,
                                modifier = Modifier.fillMaxWidth().padding(16.dp),
                            ) {
                                Text("No blobs stored", color = TertiaryText, fontSize = 13.sp)
                            }
                        }
                    }
                }
            }
        }
    }
}
