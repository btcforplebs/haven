package com.nostrvault.ui.components

import androidx.compose.animation.*
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.service.PendingPostManager
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.roundToInt

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
            animationSpec = Motion.bannerIn(),
        ) + fadeIn(Motion.bannerIn()),
        exit = slideOutVertically(targetOffsetY = { it }, animationSpec = Motion.bannerOut()) +
            fadeOut(Motion.bannerOut()),
        modifier = modifier,
    ) {
        // Swipe the banner away to get on with things — the post still goes out.
        // Accepts either direction: iOS's pill sits at the top so "swipe up" is
        // the natural gesture there, but this banner is anchored BottomCenter,
        // where swiping down is what reads as dismissal. Rather than force one
        // to match the other, both work.
        val dragOffset = remember { Animatable(0f) }
        val scope = rememberCoroutineScope()
        val dismissThresholdPx = with(LocalDensity.current) { 28.dp.toPx() }

        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp)
                .offset { IntOffset(0, dragOffset.value.roundToInt()) }
                .draggable(
                    orientation = Orientation.Vertical,
                    state = rememberDraggableState { delta ->
                        scope.launch { dragOffset.snapTo(dragOffset.value + delta) }
                    },
                    onDragStopped = {
                        if (abs(dragOffset.value) > dismissThresholdPx) {
                            pendingPostManager.dismissBanner()
                        }
                        dragOffset.animateTo(0f, Motion.snapBack())
                    },
                )
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
