package com.nostrvault.ui.screens.dashboard

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

@Composable
fun MirrorStatusSection(
    mirrors: List<MirrorInfo>,
    onRefreshHealth: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var expanded by remember { mutableStateOf(true) }

    Surface(
        color = SecondaryGroupedBg,
        shape = RoundedCornerShape(12.dp),
        modifier = modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            // Header
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    text = "Mirror Servers",
                    color = PrimaryText,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    text = "${mirrors.count { it.isHealthy == true }}/${mirrors.size} active",
                    color = SecondaryText,
                    fontSize = 12.sp,
                )
                Spacer(Modifier.width(8.dp))
                IconButton(
                    onClick = onRefreshHealth,
                    modifier = Modifier.size(28.dp),
                ) {
                    Icon(
                        NostrVaultIcons.Refresh,
                        contentDescription = "Refresh",
                        tint = SecondaryText,
                        modifier = Modifier.size(16.dp),
                    )
                }
                IconButton(
                    onClick = { expanded = !expanded },
                    modifier = Modifier.size(28.dp),
                ) {
                    Icon(
                        if (expanded) NostrVaultIcons.ChevronDown else NostrVaultIcons.Navigate,
                        contentDescription = if (expanded) "Collapse" else "Expand",
                        tint = SecondaryText,
                        modifier = Modifier.size(16.dp),
                    )
                }
            }

            AnimatedVisibility(visible = expanded) {
                Column {
                    if (mirrors.isEmpty()) {
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 16.dp),
                        ) {
                            Text(
                                text = "No mirrors configured",
                                color = TertiaryText,
                                fontSize = 13.sp,
                            )
                        }
                    } else {
                        Spacer(Modifier.height(8.dp))
                        mirrors.forEach { mirror ->
                            MirrorRow(mirror)
                            Spacer(Modifier.height(6.dp))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MirrorRow(mirror: MirrorInfo) {
    val statusColor = when (mirror.isHealthy) {
        true -> SuccessGreen
        false -> ErrorRed
        null -> WarningYellow
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
    ) {
        // Health dot
        Box(
            modifier = Modifier
                .size(8.dp)
                .background(statusColor, CircleShape),
        )
        Spacer(Modifier.width(10.dp))

        // URL
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = mirror.host,
                color = PrimaryText,
                fontSize = 13.sp,
            )
        }

        // Response time
        if (mirror.responseTimeMs != null) {
            Text(
                text = "${mirror.responseTimeMs}ms",
                color = SecondaryText,
                fontSize = 11.sp,
                fontFamily = FontFamily.Monospace,
            )
        } else if (mirror.isHealthy == null) {
            CircularProgressIndicator(
                color = WarningYellow,
                strokeWidth = 1.5.dp,
                modifier = Modifier.size(12.dp),
            )
        }
    }
}
