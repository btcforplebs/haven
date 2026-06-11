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
import com.nostrvault.relay.RelayLogParser
import com.nostrvault.ui.theme.*

private val ConsoleBg = Color(0xFF0D0D12)
private val ConsoleBorder = Color(0xFF2A2A35)

@Composable
fun CompactLogConsole(
    logs: List<RelayLogParser.LogEntry>,
    onViewAll: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val displayLogs = logs.takeLast(50)
    val listState = rememberLazyListState()

    // Auto-scroll to bottom when new entries arrive
    LaunchedEffect(displayLogs.size) {
        if (displayLogs.isNotEmpty()) {
            listState.animateScrollToItem(displayLogs.size - 1)
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
            // Terminal header
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(ConsoleBorder)
                    .padding(horizontal = 12.dp, vertical = 6.dp),
            ) {
                // Traffic light dots
                Box(Modifier.size(8.dp).background(ErrorRed, CircleShape))
                Spacer(Modifier.width(4.dp))
                Box(Modifier.size(8.dp).background(WarningYellow, CircleShape))
                Spacer(Modifier.width(4.dp))
                Box(Modifier.size(8.dp).background(SuccessGreen, CircleShape))

                Spacer(Modifier.width(12.dp))
                Text(
                    text = "CONSOLE",
                    color = SuccessGreen,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    fontFamily = FontFamily.Monospace,
                    letterSpacing = 1.sp,
                )
                Spacer(Modifier.weight(1f))
                TextButton(
                    onClick = onViewAll,
                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 2.dp),
                ) {
                    Text(
                        text = "View All",
                        color = SecondaryText,
                        fontSize = 11.sp,
                    )
                }
            }

            // Log entries
            if (displayLogs.isEmpty()) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(100.dp),
                ) {
                    Text(
                        text = "No log entries yet",
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
                        .height(140.dp)
                        .padding(horizontal = 8.dp, vertical = 4.dp),
                ) {
                    items(displayLogs, key = { it.id }) { entry ->
                        LogEntryRow(entry)
                    }
                }
            }
        }
    }
}

@Composable
private fun LogEntryRow(entry: RelayLogParser.LogEntry) {
    val levelColor = when (entry.level) {
        "ERROR" -> ErrorRed
        "WARN" -> WarningYellow
        else -> SuccessGreen
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 1.dp),
    ) {
        Text(
            text = entry.level.take(4).padEnd(4),
            color = levelColor,
            fontSize = 10.sp,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.width(6.dp))
        Text(
            text = entry.message,
            color = PrimaryText.copy(alpha = 0.85f),
            fontSize = 10.sp,
            fontFamily = FontFamily.Monospace,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
