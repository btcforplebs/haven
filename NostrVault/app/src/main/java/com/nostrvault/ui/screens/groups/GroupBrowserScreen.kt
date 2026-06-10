package com.nostrvault.ui.screens.groups

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
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

    private val _groups = MutableStateFlow<List<GroupInfo>>(emptyList())
    val groups = _groups.asStateFlow()

    private val _isLoading = MutableStateFlow(true)
    val isLoading = _isLoading.asStateFlow()

    init {
        viewModelScope.launch {
            _isLoading.value = true
            _groups.value = groupService.browseGroups()
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
        if (isLoading) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                CircularProgressIndicator(color = colors.primary)
            }
        } else if (groups.isEmpty()) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                Text("No groups found", color = SecondaryText, fontSize = 15.sp)
            }
        } else {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
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
            Text(
                text = group.name ?: group.identifier.groupId,
                color = PrimaryText,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            group.about?.takeIf { it.isNotBlank() }?.let {
                Text(
                    text = it,
                    color = SecondaryText,
                    fontSize = 13.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                text = "${group.memberCount} members",
                color = TertiaryText,
                fontSize = 12.sp,
            )
        }

        TextButton(onClick = onJoin) {
            Text("Join", color = colors.primary, fontWeight = FontWeight.SemiBold)
        }
    }
}
