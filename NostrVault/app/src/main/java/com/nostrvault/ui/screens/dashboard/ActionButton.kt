package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

@Composable
fun ActionButton(
    icon: ImageVector,
    title: String,
    isLoading: Boolean = false,
    enabled: Boolean = true,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current

    Surface(
        color = SecondaryGroupedBg,
        shape = RoundedCornerShape(12.dp),
        onClick = onClick,
        enabled = enabled && !isLoading,
        modifier = modifier,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.padding(16.dp),
        ) {
            if (isLoading) {
                CircularProgressIndicator(
                    color = colors.primary,
                    strokeWidth = 2.dp,
                    modifier = Modifier.size(24.dp),
                )
            } else {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = if (enabled) colors.primary else TertiaryText,
                    modifier = Modifier.size(24.dp),
                )
            }
            Spacer(Modifier.height(8.dp))
            Text(
                text = title,
                color = if (enabled) PrimaryText else TertiaryText,
                fontSize = 12.sp,
                textAlign = TextAlign.Center,
                maxLines = 2,
            )
        }
    }
}
