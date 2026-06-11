package com.nostrvault.ui.screens.settings

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FollowingSnapshot
import com.nostrvault.service.FeedService
import com.nostrvault.service.FollowingBackupService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import javax.inject.Inject

/**
 * Screen showing following list snapshots.
 * Tap a snapshot to see which pubkeys were added/removed compared to current following.
 */

@HiltViewModel
class FollowingBackupViewModel @Inject constructor(
    private val followingBackupService: FollowingBackupService,
    private val feedService: FeedService,
    private val configStore: ConfigStore,
) : ViewModel() {

    val snapshots = followingBackupService.snapshots

    val currentFollowingCount: Int
        get() = feedService.followedPubkeys.value.size

    val currentFollowedPubkeys: List<String>
        get() = feedService.followedPubkeys.value.toList()

    init {
        val accountKey = configStore.config.value.activeAccountNpub
            ?: configStore.config.value.ownerNpub
        followingBackupService.loadSnapshots(accountKey)
    }

    fun removedSince(snapshot: FollowingSnapshot): List<String> {
        return followingBackupService.removedSince(snapshot, currentFollowedPubkeys)
    }

    fun addedSince(snapshot: FollowingSnapshot): List<String> {
        return followingBackupService.addedSince(snapshot, currentFollowedPubkeys)
    }

    fun deleteSnapshot(id: String) {
        val accountKey = configStore.config.value.activeAccountNpub
            ?: configStore.config.value.ownerNpub
        followingBackupService.deleteSnapshot(id, accountKey)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FollowingBackupScreen(
    onBack: () -> Unit,
    viewModel: FollowingBackupViewModel = hiltViewModel(),
) {
    val snapshots by viewModel.snapshots.collectAsState()
    var expandedId by remember { mutableStateOf<String?>(null) }
    val dateFormat = remember { SimpleDateFormat("MMM d, yyyy 'at' h:mm a", Locale.getDefault()) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Following Backup") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back")
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
        if (snapshots.isEmpty()) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("No snapshots yet", color = SecondaryText, fontSize = 16.sp)
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Snapshots are created automatically when your contact list loads.",
                        color = TertiaryText,
                        fontSize = 13.sp,
                    )
                }
            }
        } else {
            LazyColumn(
                contentPadding = PaddingValues(
                    top = padding.calculateTopPadding() + 8.dp,
                    bottom = padding.calculateBottomPadding() + 16.dp,
                    start = 16.dp,
                    end = 16.dp,
                ),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                item {
                    Text(
                        text = "Current: ${viewModel.currentFollowingCount} following",
                        color = SecondaryText,
                        fontSize = 13.sp,
                        modifier = Modifier.padding(bottom = 8.dp),
                    )
                }

                itemsIndexed(snapshots, key = { _, s -> s.id }) { _, snapshot ->
                    val isExpanded = expandedId == snapshot.id

                    Surface(
                        shape = RoundedCornerShape(12.dp),
                        color = SecondaryGroupedBg,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Column(
                            modifier = Modifier
                                .clickable {
                                    expandedId = if (isExpanded) null else snapshot.id
                                }
                                .padding(16.dp),
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = dateFormat.format(Date(snapshot.capturedAt)),
                                        color = PrimaryText,
                                        fontSize = 14.sp,
                                        fontWeight = FontWeight.Medium,
                                    )
                                    Text(
                                        text = "${snapshot.followCount} following",
                                        color = SecondaryText,
                                        fontSize = 13.sp,
                                    )
                                }

                                IconButton(
                                    onClick = { viewModel.deleteSnapshot(snapshot.id) },
                                    modifier = Modifier.size(32.dp),
                                ) {
                                    Icon(
                                        imageVector = NostrVaultIcons.Delete,
                                        contentDescription = "Delete",
                                        tint = SecondaryText,
                                        modifier = Modifier.size(18.dp),
                                    )
                                }
                            }

                            AnimatedVisibility(visible = isExpanded) {
                                val removed = remember(snapshot) { viewModel.removedSince(snapshot) }
                                val added = remember(snapshot) { viewModel.addedSince(snapshot) }

                                Column(modifier = Modifier.padding(top = 12.dp)) {
                                    if (removed.isNotEmpty()) {
                                        Text(
                                            text = "Removed since (${removed.size}):",
                                            color = ErrorRed,
                                            fontSize = 13.sp,
                                            fontWeight = FontWeight.Medium,
                                        )
                                        removed.take(20).forEach { pk ->
                                            Text(
                                                text = "- ${pk.take(16)}...",
                                                color = ErrorRed.copy(alpha = 0.8f),
                                                fontSize = 12.sp,
                                                modifier = Modifier.padding(start = 8.dp),
                                            )
                                        }
                                        if (removed.size > 20) {
                                            Text(
                                                text = "  ... and ${removed.size - 20} more",
                                                color = TertiaryText,
                                                fontSize = 12.sp,
                                                modifier = Modifier.padding(start = 8.dp),
                                            )
                                        }
                                        Spacer(Modifier.height(8.dp))
                                    }

                                    if (added.isNotEmpty()) {
                                        Text(
                                            text = "Added since (${added.size}):",
                                            color = SuccessGreen,
                                            fontSize = 13.sp,
                                            fontWeight = FontWeight.Medium,
                                        )
                                        added.take(20).forEach { pk ->
                                            Text(
                                                text = "+ ${pk.take(16)}...",
                                                color = SuccessGreen.copy(alpha = 0.8f),
                                                fontSize = 12.sp,
                                                modifier = Modifier.padding(start = 8.dp),
                                            )
                                        }
                                        if (added.size > 20) {
                                            Text(
                                                text = "  ... and ${added.size - 20} more",
                                                color = TertiaryText,
                                                fontSize = 12.sp,
                                                modifier = Modifier.padding(start = 8.dp),
                                            )
                                        }
                                    }

                                    if (removed.isEmpty() && added.isEmpty()) {
                                        Text(
                                            text = "No changes since this snapshot",
                                            color = TertiaryText,
                                            fontSize = 13.sp,
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
