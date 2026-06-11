package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.service.StatsService
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.launch
import java.text.NumberFormat

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EventKindBreakdownSheet(
    statsService: StatsService,
    onDismiss: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val kindCounts by statsService.kindCounts.collectAsState()
    val isLoading by statsService.isUpdatingCount.collectAsState()
    val scope = rememberCoroutineScope()

    val sortedKinds = remember(kindCounts) {
        kindCounts.entries.sortedByDescending { it.value }
    }
    val totalEvents = remember(kindCounts) {
        kindCounts.values.sum()
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = WindowBackground,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(bottom = 32.dp),
        ) {
            // Header
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "Event Breakdown",
                        color = PrimaryText,
                        fontSize = 18.sp,
                        fontWeight = FontWeight.Bold,
                    )
                    Text(
                        text = NumberFormat.getIntegerInstance().format(totalEvents) + " total events",
                        color = SecondaryText,
                        fontSize = 13.sp,
                    )
                }
                IconButton(
                    onClick = { scope.launch { statsService.fetchCountsByKind() } },
                    modifier = Modifier.size(32.dp),
                ) {
                    Icon(NostrVaultIcons.Refresh, "Refresh", tint = SecondaryText, modifier = Modifier.size(18.dp))
                }
            }

            Spacer(Modifier.height(16.dp))

            if (isLoading && sortedKinds.isEmpty()) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier.fillMaxWidth().padding(32.dp),
                ) {
                    CircularProgressIndicator(color = colors.primary)
                }
            } else {
                Surface(
                    color = SecondaryGroupedBg,
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        sortedKinds.forEachIndexed { index, (kind, count) ->
                            KindRow(
                                kind = kind,
                                name = kindNames[kind] ?: "Kind $kind",
                                count = count,
                                total = totalEvents,
                            )
                            if (index < sortedKinds.size - 1) {
                                HorizontalDivider(
                                    color = TertiaryText.copy(alpha = 0.2f),
                                    modifier = Modifier.padding(vertical = 4.dp),
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
