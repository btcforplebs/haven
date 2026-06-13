package com.nostrvault.ui.screens.groups

import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.service.GroupInfo
import com.nostrvault.service.GroupService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Browse available groups on known relay servers.
 */

@HiltViewModel
class GroupBrowserViewModel @Inject constructor(
    private val groupService: GroupService,
) : ViewModel() {

    val groups = groupService.availableGroups

    private val _isLoading = MutableStateFlow(true)
    val isLoading = _isLoading.asStateFlow()

    private val _relayInput = MutableStateFlow("")
    val relayInput = _relayInput.asStateFlow()

    val savedRelays: List<String> = groupService.knownGroupRelays()

    init {
        viewModelScope.launch {
            _isLoading.value = true
            groupService.browseGroups()
            delay(2_000)
            _isLoading.value = false
        }
    }

    fun setRelayInput(v: String) { _relayInput.value = v }

    fun browse(relayUrl: String) {
        val relay = relayUrl.trim()
        if (!relay.startsWith("wss://")) return
        _relayInput.value = relay
        viewModelScope.launch {
            _isLoading.value = true
            groupService.browseGroups(relay)
            delay(2_000)
            _isLoading.value = false
        }
    }

    fun joinGroup(groupId: String, relayUrl: String) {
        viewModelScope.launch {
            groupService.joinGroup(groupId, relayUrl)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GroupBrowserScreen(
    onGroupClick: (String, String) -> Unit,
    onBack: () -> Unit,
    viewModel: GroupBrowserViewModel = hiltViewModel(),
) {
    val groups by viewModel.groups.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val relayInput by viewModel.relayInput.collectAsState()
    val colors = LocalNostrVaultColors.current

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Browse Groups") },
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
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            // Relay URL input + browse
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
            ) {
                OutlinedTextField(
                    value = relayInput,
                    onValueChange = viewModel::setRelayInput,
                    placeholder = { Text("wss://groups.example.com") },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = PrimaryText, unfocusedTextColor = PrimaryText,
                        cursorColor = colors.primary, focusedBorderColor = colors.primary,
                    ),
                )
                Spacer(Modifier.width(8.dp))
                Button(
                    onClick = { viewModel.browse(relayInput) },
                    enabled = relayInput.isNotBlank(),
                    colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                ) { Text("Browse") }
            }

            // Saved relay quick-chips
            if (viewModel.savedRelays.isNotEmpty()) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = 16.dp),
                ) {
                    viewModel.savedRelays.forEach { url ->
                        AssistChip(
                            onClick = { viewModel.browse(url) },
                            label = { Text(url.removePrefix("wss://"), fontSize = 12.sp) },
                        )
                    }
                }
            }

            when {
                isLoading -> Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier.fillMaxSize(),
                ) { CircularProgressIndicator(color = colors.primary) }

                groups.isEmpty() -> Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier.fillMaxSize(),
                ) { Text("No groups found", color = SecondaryText, fontSize = 15.sp) }

                else -> LazyColumn(modifier = Modifier.fillMaxSize()) {
                    items(groups, key = { "${it.identifier.groupId}_${it.identifier.relayURL}" }) { group ->
                        BrowseGroupRow(
                            group = group,
                            onClick = { onGroupClick(group.identifier.groupId, group.identifier.relayURL) },
                            onJoin = { viewModel.joinGroup(group.identifier.groupId, group.identifier.relayURL) },
                        )
                        HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
                    }
                }
            }
        }
    }
}

@Composable
private fun BrowseGroupRow(
    group: GroupInfo,
    onClick: () -> Unit,
    onJoin: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Surface(
            color = colors.primaryPale,
            shape = RoundedCornerShape(8.dp),
            modifier = Modifier.size(44.dp),
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    imageVector = NostrVaultIcons.Groups,
                    contentDescription = null,
                    tint = colors.primary,
                    modifier = Modifier.size(22.dp),
                )
            }
        }

        Spacer(Modifier.width(12.dp))

        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = group.name ?: group.identifier.groupId,
                    color = PrimaryText,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (group.isPrivate) {
                    Spacer(Modifier.width(4.dp))
                    Text("🔒", fontSize = 12.sp)
                }
                if (group.isClosed) {
                    Spacer(Modifier.width(4.dp))
                    Text("✋", fontSize = 12.sp)
                }
            }
            group.about?.takeIf { it.isNotBlank() }?.let {
                Text(
                    text = it,
                    color = SecondaryText,
                    fontSize = 13.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            group.memberCount?.let { count ->
                Text(
                    text = "$count members",
                    color = TertiaryText,
                    fontSize = 12.sp,
                )
            }
        }

        TextButton(onClick = onJoin) {
            Text("Join", color = colors.primary, fontWeight = FontWeight.SemiBold)
        }
    }
}
