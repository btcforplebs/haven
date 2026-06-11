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
import com.nostrvault.service.StatsService
import com.nostrvault.ui.theme.*

private val DatabaseColor = Color(0xFF5E5CE6) // indigo
private val BlossomColor = Color(0xFF30D158)   // green
private val CacheColor = Color(0xFFFF9F0A)     // orange
private val ThumbnailColor = Color(0xFF64D2FF) // cyan

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StorageBreakdownSheet(
    statsService: StatsService,
    onDismiss: () -> Unit,
) {
    val storageSize by statsService.storageSize.collectAsState()
    val blossomSize by statsService.blossomSize.collectAsState()
    val cacheSize by statsService.cacheSize.collectAsState()
    val thumbnailSize by statsService.thumbnailSize.collectAsState()

    val totalSize = storageSize + blossomSize + cacheSize + thumbnailSize

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
                        text = "Storage Breakdown",
                        color = PrimaryText,
                        fontSize = 18.sp,
                        fontWeight = FontWeight.Bold,
                    )
                    Text(
                        text = formatSize(totalSize) + " total",
                        color = SecondaryText,
                        fontSize = 13.sp,
                    )
                }
                IconButton(
                    onClick = { statsService.refreshStats() },
                    modifier = Modifier.size(32.dp),
                ) {
                    Icon(NostrVaultIcons.Refresh, "Refresh", tint = SecondaryText, modifier = Modifier.size(18.dp))
                }
            }

            Surface(
                color = SecondaryGroupedBg,
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    StorageRow(
                        label = "Database",
                        icon = NostrVaultIcons.Storage,
                        color = DatabaseColor,
                        size = storageSize,
                        total = totalSize,
                    )
                    HorizontalDivider(color = TertiaryText.copy(alpha = 0.2f), modifier = Modifier.padding(vertical = 4.dp))
                    StorageRow(
                        label = "Blossom Media",
                        icon = NostrVaultIcons.Blossom,
                        color = BlossomColor,
                        size = blossomSize,
                        total = totalSize,
                    )
                    HorizontalDivider(color = TertiaryText.copy(alpha = 0.2f), modifier = Modifier.padding(vertical = 4.dp))
                    StorageRow(
                        label = "Media Cache",
                        icon = NostrVaultIcons.Media,
                        color = CacheColor,
                        size = cacheSize,
                        total = totalSize,
                    )
                    HorizontalDivider(color = TertiaryText.copy(alpha = 0.2f), modifier = Modifier.padding(vertical = 4.dp))
                    StorageRow(
                        label = "Thumbnails",
                        icon = NostrVaultIcons.GridLayout,
                        color = ThumbnailColor,
                        size = thumbnailSize,
                        total = totalSize,
                    )
                }
            }
        }
    }
}
