package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private val ConsoleBg = Color(0xFF0D0D12)
private val ConsoleBorder = Color(0xFF2A2A35)

@Composable
fun BlossomActivityLogView(
    logs: List<BlossomActivityLog>,
    modifier: Modifier = Modifier,
) {
    val listState = rememberLazyListState()
    val timeFormat = SimpleDateFormat("HH:mm:ss", Locale.getDefault())

    LaunchedEffect(logs.size) {
        if (logs.isNotEmpty()) {
            listState.animateScrollToItem(logs.size - 1)
        }
    }

    Surface(
        color = ConsoleBg,
        shape = RoundedCornerShape(12.dp),
        modifier = modifier
            .fillMaxWidth()
            .border(1.dp, ConsoleBorder, RoundedCornerShape(12.dp)),
    ) {
        Column {
            // Header
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(ConsoleBorder)
                    .padding(horizontal = 12.dp, vertical = 6.dp),
            ) {
                Box(Modifier.size(8.dp).background(ErrorRed, CircleShape))
                Spacer(Modifier.width(4.dp))
                Box(Modifier.size(8.dp).background(WarningYellow, CircleShape))
                Spacer(Modifier.width(4.dp))
                Box(Modifier.size(8.dp).background(SuccessGreen, CircleShape))
                Spacer(Modifier.width(12.dp))
                Text(
                    text = "ACTIVITY",
                    color = SuccessGreen,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    fontFamily = FontFamily.Monospace,
                    letterSpacing = 1.sp,
                )
            }

            if (logs.isEmpty()) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(80.dp),
                ) {
                    Text(
                        text = "No activity yet",
                        color = TertiaryText,
                        fontSize = 12.sp,
                        fontFamily = FontFamily.Monospace,
                    )
                }
            } else {
                LazyColumn(
                    state = listState,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(120.dp)
                        .padding(horizontal = 8.dp, vertical = 4.dp),
                ) {
                    items(logs, key = { it.id }) { entry ->
                        val levelColor = when (entry.level) {
                            BlossomActivityLog.LogLevel.SUCCESS -> SuccessGreen
                            BlossomActivityLog.LogLevel.WARNING -> WarningYellow
                            BlossomActivityLog.LogLevel.ERROR -> ErrorRed
                            BlossomActivityLog.LogLevel.INFO -> SecondaryText
                        }
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 1.dp),
                        ) {
                            Text(
                                text = timeFormat.format(Date(entry.timestamp)),
                                color = TertiaryText,
                                fontSize = 9.sp,
                                fontFamily = FontFamily.Monospace,
                            )
                            Spacer(Modifier.width(6.dp))
                            Text(
                                text = entry.message,
                                color = levelColor,
                                fontSize = 10.sp,
                                fontFamily = FontFamily.Monospace,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
            }
        }
    }
}
