package com.nostrvault.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.ui.theme.*
import java.util.Date

/**
 * Inline engagement bar matching iOS VaultNoteRow.engagementBar exactly.
 *
 * Layout (from iOS lines 441-544):
 *   HStack(spacing: 14) {
 *     [reactions]  [reposts]  [quotes]  [zaps]  Spacer()
 *   }
 *
 * Each metric is HStack(spacing: 4) { icon, overlapping avatars, count }
 * Reactions also include timeAgo after the count.
 * Spacer() at the end left-aligns the metrics.
 */
@Composable
fun InlineEngagementBar(
    reactors: List<Pair<String, String>>,
    latestReactionDate: Date?,
    reposterPubkeys: List<String>,
    quoterPubkeys: List<String>,
    zappers: List<Pair<String, Long>>,
    profiles: Map<String, FeedProfile>,
    onReactorsClick: (() -> Unit)? = null,
    onRepostersClick: (() -> Unit)? = null,
    onQuotersClick: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val uniqueReactors = reactors.distinctBy { it.first }
    val uniqueReposters = reposterPubkeys.distinct()
    val uniqueQuoters = quoterPubkeys.distinct()
    val uniqueZapperPubkeys = zappers.map { it.first }.distinct()
    val totalSats = zappers.sumOf { it.second }

    if (uniqueReactors.isEmpty() && uniqueReposters.isEmpty() &&
        uniqueQuoters.isEmpty() && uniqueZapperPubkeys.isEmpty()) {
        return
    }

    Column(modifier = modifier) {
        // Separator: iOS Rectangle().fill(Color.secondary.opacity(0.12)).frame(height: 0.5).padding(.top, 6)
        HorizontalDivider(
            color = SecondaryText.copy(alpha = 0.12f),
            thickness = 0.5.dp,
            modifier = Modifier.padding(top = 6.dp),
        )

        // iOS: HStack(spacing: 14) { ... Spacer() }.padding(.top, 6)
        Row(
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 6.dp),
        ) {
            // Reactions — includes timeAgo inside (iOS lines 443-471)
            if (uniqueReactors.isNotEmpty()) {
                val clickMod = if (onReactorsClick != null) Modifier.clickable(onClick = onReactorsClick) else Modifier
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                    modifier = clickMod,
                ) {
                    Icon(
                        imageVector = NostrVaultIcons.HeartFilled,
                        contentDescription = null,
                        tint = LikeRed,
                        modifier = Modifier.size(10.dp),
                    )
                    OverlappingAvatars(
                        pubkeys = uniqueReactors.map { it.first },
                        profiles = profiles,
                    )
                    Text(
                        text = "${uniqueReactors.size}",
                        color = LikeRed.copy(alpha = 0.8f),
                        fontSize = 11.sp,
                        fontFamily = FontFamily.Monospace,
                        fontWeight = FontWeight.SemiBold,
                    )
                    // timeAgo inside reactions (iOS lines 463-467)
                    if (latestReactionDate != null) {
                        Text(
                            text = formatTimeAgo(latestReactionDate.time / 1000),
                            color = SecondaryText.copy(alpha = 0.6f),
                            fontSize = 10.sp,
                            fontFamily = FontFamily.Monospace,
                        )
                    }
                }
            }

            // Reposts (iOS lines 474-496)
            if (uniqueReposters.isNotEmpty()) {
                MetricGroup(
                    icon = NostrVaultIcons.Repost,
                    iconColor = RepostGreen,
                    pubkeys = uniqueReposters,
                    label = "${uniqueReposters.size}",
                    labelColor = RepostGreen.copy(alpha = 0.8f),
                    profiles = profiles,
                    onClick = onRepostersClick,
                )
            }

            // Quotes (iOS lines 498-521)
            if (uniqueQuoters.isNotEmpty()) {
                MetricGroup(
                    icon = NostrVaultIcons.Quote,
                    iconColor = Color(0xFF5E9FFF),
                    pubkeys = uniqueQuoters,
                    label = "${uniqueQuoters.size}",
                    labelColor = Color(0xFF5E9FFF).copy(alpha = 0.8f),
                    profiles = profiles,
                    onClick = onQuotersClick,
                )
            }

            // Zaps (iOS lines 524-541)
            if (uniqueZapperPubkeys.isNotEmpty()) {
                MetricGroup(
                    icon = NostrVaultIcons.Zap,
                    iconColor = ZapOrange,
                    pubkeys = uniqueZapperPubkeys,
                    label = formatSats(totalSats),
                    labelColor = ZapOrange.copy(alpha = 0.8f),
                    profiles = profiles,
                    onClick = null,
                )
            }

            // iOS: Spacer() — left-aligns everything
            Spacer(Modifier.weight(1f))
        }
    }
}

/**
 * Single metric group: icon + overlapping avatars + label.
 * Matches iOS HStack(spacing: 4) { Image, HStack(spacing: -4) { avatars }, Text }
 */
@Composable
private fun MetricGroup(
    icon: ImageVector,
    iconColor: Color,
    pubkeys: List<String>,
    label: String,
    labelColor: Color,
    profiles: Map<String, FeedProfile>,
    onClick: (() -> Unit)?,
) {
    val clickMod = if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        modifier = clickMod,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = iconColor,
            modifier = Modifier.size(10.dp),
        )
        OverlappingAvatars(
            pubkeys = pubkeys,
            profiles = profiles,
        )
        Text(
            text = label,
            color = labelColor,
            fontSize = 11.sp,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

private fun formatSats(sats: Long): String {
    return when {
        sats >= 1_000_000 -> "%.1fM sats".format(sats / 1_000_000.0)
        sats >= 10_000 -> "%.1fK sats".format(sats / 1_000.0)
        else -> "%,d sats".format(sats)
    }
}

private fun formatTimeAgo(epochSecs: Long): String {
    val now = System.currentTimeMillis() / 1000
    val diff = now - epochSecs
    return when {
        diff < 60 -> "now"
        diff < 3600 -> "${diff / 60}m"
        diff < 86400 -> "${diff / 3600}h"
        diff < 604800 -> "${diff / 86400}d"
        else -> "${diff / 604800}w"
    }
}
