package com.nostrvault.ui.screens.settings

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FollowingSnapshot
import com.nostrvault.data.model.Kind3Event
import com.nostrvault.service.FeedService
import com.nostrvault.service.FollowingBackupService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
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

    private val _scannedEvents = MutableStateFlow<List<Kind3Event>>(emptyList())
    val scannedEvents = _scannedEvents.asStateFlow()

    private val _isScanning = MutableStateFlow(false)
    val isScanning = _isScanning.asStateFlow()

    val currentFollowingCount: Int
        get() = feedService.followedPubkeys.value.size

    val currentFollowedPubkeys: List<String>
        get() = feedService.followedPubkeys.value.toList()

    init {
        val accountKey = configStore.config.value.activeAccountNpub
            ?: configStore.config.value.ownerNpub
        followingBackupService.loadSnapshots(accountKey)
    }

    fun scanRelays() {
        if (_isScanning.value) return
        viewModelScope.launch {
            _isScanning.value = true
            try {
                _scannedEvents.value = feedService.scanRelaysForKind3()
            } finally {
                _isScanning.value = false
            }
        }
    }

    fun restoreList(pTags: List<List<String>>, content: String) {
        feedService.restoreContactList(pTags, content)
    }

    fun refollow(pubkey: String) {
        feedService.followUser(pubkey)
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
        val scannedEvents by viewModel.scannedEvents.collectAsState()
        val isScanning by viewModel.isScanning.collectAsState()

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
            // ── Relay recovery section ──────────────────────────────
            item {
                Column {
                    Button(
                        onClick = { viewModel.scanRelays() },
                        enabled = !isScanning,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        if (isScanning) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(16.dp),
                                strokeWidth = 2.dp,
                                color = Color.White,
                            )
                            Spacer(Modifier.width(8.dp))
                            Text("Scanning relays…")
                        } else {
                            Text(if (scannedEvents.isEmpty()) "Scan Relays for Backups" else "Rescan Relays")
                        }
                    }
                    Text(
                        "Search your relays for historical contact lists you can restore.",
                        color = TertiaryText,
                        fontSize = 12.sp,
                        modifier = Modifier.padding(top = 6.dp, bottom = 4.dp),
                    )
                }
            }

            items(scannedEvents, key = { it.id }) { event ->
                Surface(
                    shape = RoundedCornerShape(12.dp),
                    color = SecondaryGroupedBg,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(16.dp),
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = dateFormat.format(Date(event.createdAt * 1000)),
                                color = PrimaryText,
                                fontSize = 14.sp,
                                fontWeight = FontWeight.Medium,
                            )
                            Text(
                                text = "${event.followCount} following (from relay)",
                                color = SecondaryText,
                                fontSize = 13.sp,
                            )
                        }
                        TextButton(onClick = { viewModel.restoreList(event.pTags, event.content) }) {
                            Text("Restore")
                        }
                    }
                }
            }

            item {
                Text(
                    text = "Current: ${viewModel.currentFollowingCount} following",
                    color = SecondaryText,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(top = 8.dp, bottom = 4.dp),
                )
            }

            if (snapshots.isEmpty()) {
                item {
                    Text(
                        "No local snapshots yet. Snapshots are created automatically when your contact list loads.",
                        color = TertiaryText,
                        fontSize = 13.sp,
                        modifier = Modifier.padding(vertical = 8.dp),
                    )
                }
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
                                            Row(
                                                verticalAlignment = Alignment.CenterVertically,
                                                modifier = Modifier.padding(start = 8.dp),
                                            ) {
                                                Text(
                                                    text = "- ${pk.take(16)}...",
                                                    color = ErrorRed.copy(alpha = 0.8f),
                                                    fontSize = 12.sp,
                                                    modifier = Modifier.weight(1f),
                                                )
                                                TextButton(
                                                    onClick = { viewModel.refollow(pk) },
                                                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                                                ) { Text("Re-follow", fontSize = 12.sp) }
                                            }
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

                                    Spacer(Modifier.height(12.dp))
                                    Button(
                                        onClick = {
                                            viewModel.restoreList(snapshot.pTags, snapshot.contactListContent)
                                        },
                                        modifier = Modifier.fillMaxWidth(),
                                    ) { Text("Restore This List") }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
