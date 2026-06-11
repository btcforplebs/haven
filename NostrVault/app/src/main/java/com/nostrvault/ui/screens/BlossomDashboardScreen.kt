package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.nostrvault.ui.screens.dashboard.*
import com.nostrvault.ui.theme.*

/**
 * Blossom media server dashboard: stats, mirror management, pull/push sync, activity log.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BlossomDashboardScreen(
    onBack: () -> Unit,
    viewModel: BlossomDashboardViewModel = hiltViewModel(),
) {
    val totalFiles by viewModel.totalFiles.collectAsState()
    val totalSize by viewModel.totalSize.collectAsState()
    val isLoadingStats by viewModel.isLoadingStats.collectAsState()
    val mirrors by viewModel.mirrors.collectAsState()
    val isPulling by viewModel.isPulling.collectAsState()
    val isPushing by viewModel.isPushing.collectAsState()
    val syncMessage by viewModel.syncMessage.collectAsState()
    val activityLogs by viewModel.activityLogs.collectAsState()

    val colors = LocalNostrVaultColors.current
    val activeMirrors = mirrors.count { it.isHealthy == true }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Blossom Media") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = viewModel::loadDashboard) {
                        Icon(NostrVaultIcons.Refresh, "Refresh", tint = SecondaryText)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = WindowBackground,
                    titleContentColor = PrimaryText,
                    navigationIconContentColor = PrimaryText,
                ),
            )
        },
        containerColor = WindowBackground,
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            // ── Stats cards ──────────────────────────────────────

            if (isLoadingStats) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(32.dp),
                ) {
                    CircularProgressIndicator(color = colors.primary)
                }
            } else {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    BlossomStatCard(
                        title = "Total Files",
                        value = totalFiles.toString(),
                        icon = NostrVaultIcons.Blossom,
                        modifier = Modifier.weight(1f),
                    )
                    BlossomStatCard(
                        title = "Storage Used",
                        value = formatSize(totalSize),
                        icon = NostrVaultIcons.Storage,
                        modifier = Modifier.weight(1f),
                    )
                }

                Spacer(Modifier.height(12.dp))

                Row(
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    BlossomStatCard(
                        title = "Active Mirrors",
                        value = "$activeMirrors",
                        icon = NostrVaultIcons.Relay,
                        modifier = Modifier.weight(1f),
                    )
                    BlossomStatCard(
                        title = "Configured",
                        value = "${mirrors.size}",
                        icon = NostrVaultIcons.Settings,
                        modifier = Modifier.weight(1f),
                    )
                }
            }

            Spacer(Modifier.height(24.dp))

            // ── Quick actions ────────────────────────────────────

            Text(
                text = "Quick Actions",
                color = PrimaryText,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(bottom = 12.dp),
            )

            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                ActionButton(
                    icon = NostrVaultIcons.Import,
                    title = "Pull",
                    isLoading = isPulling,
                    enabled = !isPulling && !isPushing,
                    modifier = Modifier.weight(1f),
                    onClick = viewModel::pullFromNotes,
                )
                ActionButton(
                    icon = NostrVaultIcons.UploadIcon,
                    title = "Push",
                    isLoading = isPushing,
                    enabled = !isPulling && !isPushing,
                    modifier = Modifier.weight(1f),
                    onClick = viewModel::pushToMirrors,
                )
                ActionButton(
                    icon = NostrVaultIcons.Refresh,
                    title = "Refresh",
                    enabled = !isPulling && !isPushing,
                    modifier = Modifier.weight(1f),
                    onClick = viewModel::loadDashboard,
                )
            }

            // Sync message
            if (syncMessage.isNotBlank()) {
                Spacer(Modifier.height(8.dp))
                Text(
                    text = syncMessage,
                    color = SecondaryText,
                    fontSize = 12.sp,
                )
            }

            Spacer(Modifier.height(24.dp))

            // ── Mirror status ────────────────────────────────────

            MirrorStatusSection(
                mirrors = mirrors,
                onRefreshHealth = viewModel::checkMirrorHealth,
            )

            Spacer(Modifier.height(24.dp))

            // ── Activity log ─────────────────────────────────────

            Text(
                text = "Activity",
                color = PrimaryText,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(bottom = 12.dp),
            )

            BlossomActivityLogView(logs = activityLogs)
        }
    }
}

@Composable
private fun BlossomStatCard(
    title: String,
    value: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    modifier: Modifier = Modifier,
) {
    val colors = LocalNostrVaultColors.current

    Surface(
        color = SecondaryGroupedBg,
        shape = RoundedCornerShape(12.dp),
        modifier = modifier,
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = colors.primary,
                modifier = Modifier.size(20.dp),
            )
            Spacer(Modifier.height(8.dp))
            Text(
                text = value,
                color = PrimaryText,
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
            )
            Text(
                text = title,
                color = SecondaryText,
                fontSize = 12.sp,
            )
        }
    }
}
