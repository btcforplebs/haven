package com.nostrvault.ui.components

import androidx.compose.animation.*
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.service.PendingPostManager
import com.nostrvault.ui.theme.*

/**
 * Animated bottom banner showing a countdown before a post is published.
 * Provides Cancel and Edit buttons during the countdown.
 */
@Composable
fun PendingPostBanner(
    pendingPostManager: PendingPostManager,
    modifier: Modifier = Modifier,
) {
    val isShowing by pendingPostManager.isShowing.collectAsState()
    val actionType by pendingPostManager.actionType.collectAsState()
    val timeRemaining by pendingPostManager.timeRemaining.collectAsState()
    val colors = LocalNostrVaultColors.current

    AnimatedVisibility(
        visible = isShowing,
        enter = slideInVertically(
            initialOffsetY = { it },
            animationSpec = spring(dampingRatio = 0.7f, stiffness = 400f),
        ) + fadeIn(),
        exit = slideOutVertically(targetOffsetY = { it }) + fadeOut(),
        modifier = modifier,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp)
                .clip(RoundedCornerShape(16.dp))
                .background(SecondaryGroupedBg)
                .padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            // Progress arc via LinearProgressIndicator
            val progress = timeRemaining / (PendingPostManager.COUNTDOWN_DURATION_MS / 1000f)
            CircularProgressIndicator(
                progress = { progress },
                color = colors.primary,
                trackColor = TertiaryGroupedBg,
                strokeWidth = 3.dp,
                modifier = Modifier.size(28.dp),
            )

            Spacer(Modifier.width(12.dp))

            // Action label
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = actionType?.label ?: "Pending",
                    color = PrimaryText,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    text = String.format("%.1fs", timeRemaining),
                    color = SecondaryText,
                    fontSize = 13.sp,
                )
            }

            // Edit button (only for editable types)
            if (actionType?.canEdit == true) {
                TextButton(onClick = { pendingPostManager.requestEdit() }) {
                    Text(
                        text = "Edit",
                        color = colors.primary,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }

            // Cancel button
            TextButton(onClick = { pendingPostManager.cancel() }) {
                Text(
                    text = "Cancel",
                    color = SecondaryText,
                    fontSize = 14.sp,
                )
            }
        }
    }
}
