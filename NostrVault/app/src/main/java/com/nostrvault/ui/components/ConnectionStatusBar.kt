package com.nostrvault.ui.components

import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.Motion
import com.nostrvault.ui.theme.SecondaryText

/**
 * Compact connection status indicator with colored dot and label.
 * Used in feed and dashboard headers.
 */
@Composable
fun ConnectionStatusBar(
    status: String,
    color: String,
    modifier: Modifier = Modifier,
) {
    val dotColor = when (color) {
        "green" -> Color(0xFF34C759)
        "yellow" -> Color(0xFFFFCC00)
        "red" -> Color(0xFFFF3B30)
        else -> Color(0xFF8E8E93)
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
        modifier = modifier,
    ) {
        Box(
            modifier = Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(dotColor),
        )
        Spacer(Modifier.width(6.dp))
        Text(
            text = status,
            color = SecondaryText,
            fontSize = 12.sp,
        )
    }
}

/**
 * Syncing pill shown inline when background top-up is active.
 */
@Composable
fun SyncingPill(
    visible: Boolean,
    modifier: Modifier = Modifier,
) {
    AnimatedVisibility(
        visible = visible,
        enter = fadeIn(Motion.panel()) + expandVertically(Motion.panel()),
        exit = fadeOut(Motion.panel()) + shrinkVertically(Motion.panel()),
        modifier = modifier,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center,
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 4.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(6.dp)
                    .clip(CircleShape)
                    .background(Color(0xFFFFCC00)),
            )
            Spacer(Modifier.width(4.dp))
            Text(
                text = "Syncing...",
                color = SecondaryText,
                fontSize = 11.sp,
            )
        }
    }
}
