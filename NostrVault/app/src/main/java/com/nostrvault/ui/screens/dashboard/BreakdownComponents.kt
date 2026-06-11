package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*
import java.text.NumberFormat

val kindNames = mapOf(
    0 to "Profile Metadata",
    1 to "Short Notes",
    3 to "Contacts",
    4 to "Encrypted DMs (NIP-04)",
    5 to "Deletions",
    6 to "Reposts",
    7 to "Reactions",
    9 to "Chat Messages",
    11 to "Channel Create",
    12 to "Channel Metadata",
    16 to "Generic Repost",
    1059 to "Gift Wrapped DMs (NIP-44)",
    1063 to "File Metadata",
    9735 to "Zap Receipts",
    10000 to "Mute List",
    10002 to "Relay List",
    10050 to "DM Relays",
    10063 to "User Server List",
    30023 to "Long-form Articles",
    30078 to "App Data",
    39000 to "Group Metadata",
    39001 to "Group Admins",
    39002 to "Group Members",
)

fun formatSize(bytes: Long): String {
    if (bytes < 1024) return "$bytes B"
    val kb = bytes / 1024.0
    if (kb < 1024) return "%.1f KB".format(kb)
    val mb = kb / 1024.0
    if (mb < 1024) return "%.1f MB".format(mb)
    val gb = mb / 1024.0
    return "%.2f GB".format(gb)
}

@Composable
fun KindRow(
    kind: Int,
    name: String,
    count: Int,
    total: Int,
) {
    val percentage = if (total > 0) count.toFloat() / total else 0f
    val formatted = NumberFormat.getIntegerInstance().format(count)

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = name,
                    color = PrimaryText,
                    fontSize = 13.sp,
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    text = "kind $kind",
                    color = TertiaryText,
                    fontSize = 10.sp,
                    fontFamily = FontFamily.Monospace,
                )
            }
            Spacer(Modifier.height(4.dp))
            // Progress bar
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(4.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(SecondaryGroupedBg),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth(percentage)
                        .height(4.dp)
                        .clip(RoundedCornerShape(2.dp))
                        .background(LocalNostrVaultColors.current.primary),
                )
            }
        }

        Spacer(Modifier.width(12.dp))

        Column(horizontalAlignment = Alignment.End) {
            Text(
                text = formatted,
                color = PrimaryText,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                fontFamily = FontFamily.Monospace,
            )
            Text(
                text = "%.1f%%".format(percentage * 100),
                color = SecondaryText,
                fontSize = 10.sp,
            )
        }
    }
}

@Composable
fun StorageRow(
    label: String,
    icon: ImageVector,
    color: Color,
    size: Long,
    total: Long,
) {
    val percentage = if (total > 0) size.toFloat() / total else 0f

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = color,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(text = label, color = PrimaryText, fontSize = 14.sp)
            Spacer(Modifier.height(4.dp))
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(6.dp)
                    .clip(RoundedCornerShape(3.dp))
                    .background(SecondaryGroupedBg),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth(percentage)
                        .height(6.dp)
                        .clip(RoundedCornerShape(3.dp))
                        .background(color),
                )
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(horizontalAlignment = Alignment.End) {
            Text(
                text = formatSize(size),
                color = PrimaryText,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "%.0f%%".format(percentage * 100),
                color = SecondaryText,
                fontSize = 10.sp,
            )
        }
    }
}

@Composable
fun BlobTypeRow(
    label: String,
    icon: ImageVector,
    color: Color,
    count: Int,
    size: Long,
    total: Long,
) {
    val percentage = if (total > 0) size.toFloat() / total else 0f
    val formatted = NumberFormat.getIntegerInstance().format(count)

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = color,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(text = label, color = PrimaryText, fontSize = 14.sp)
            Spacer(Modifier.height(4.dp))
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(6.dp)
                    .clip(RoundedCornerShape(3.dp))
                    .background(SecondaryGroupedBg),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth(percentage)
                        .height(6.dp)
                        .clip(RoundedCornerShape(3.dp))
                        .background(color),
                )
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(horizontalAlignment = Alignment.End) {
            Text(
                text = "$formatted files",
                color = PrimaryText,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = formatSize(size),
                color = SecondaryText,
                fontSize = 10.sp,
            )
        }
    }
}
