package com.nostrvault.ui.notification

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Top-of-screen overlay that renders all active notification pills.
 * Placed inside the root Box of NostrVaultNavHost, at Alignment.TopCenter.
 *
 * Animations match the iOS banner pattern:
 *   enter = slide from top + fade in (spring)
 *   exit  = fade out + scale down to 80%
 */
@Composable
fun NotificationOverlay(
    notificationManager: NotificationManager,
    modifier: Modifier = Modifier,
) {
    val notifications by notificationManager.notifications.collectAsState()

    if (notifications.isEmpty()) return

    Column(
        modifier = modifier
            .fillMaxWidth()
            .statusBarsPadding()
            .padding(top = 12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        notifications.forEach { notification ->
            key(notification.id) {
                AnimatedVisibility(
                    visible = true,
                    enter = slideInVertically(
                        initialOffsetY = { -it },
                        animationSpec = spring(
                            dampingRatio = 0.75f,
                            stiffness = 400f,
                        ),
                    ) + fadeIn(),
                    exit = fadeOut() + scaleOut(targetScale = 0.8f),
                ) {
                    when (notification) {
                        is ZapNotification -> ZapPill(notification)
                        is FollowNotification -> FollowPill(notification)
                        is ErrorNotification -> ErrorPill(notification)
                        is ActionToast -> ActionToastPill(notification)
                        is UploadNotification -> UploadPill(notification)
                        is UnlikeCountdown -> UnlikeCountdownPill(notification) {
                            notificationManager.cancelUnlikeCountdown()
                        }
                    }
                }
            }
        }
    }
}
