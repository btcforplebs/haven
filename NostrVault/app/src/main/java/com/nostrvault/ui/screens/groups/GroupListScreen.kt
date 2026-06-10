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
import com.nostrvault.service.GroupService
import com.nostrvault.service.JoinedGroup
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * List of joined NIP-29 groups.
 * Port of GroupListView.swift.
 */

@HiltViewModel
class GroupListViewModel @Inject constructor(
    private val groupService: GroupService,
) : ViewModel() {

    val joinedGroups = groupService.joinedGroups

    private val _isLoading = MutableStateFlow(true)
    val isLoading = _isLoading.asStateFlow()

    init {
        viewModelScope.launch {
            groupService.loadJoinedGroups()
            _isLoading.value = false
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GroupListScreen(
    onGroupClick: (String, String) -> Unit,
    onBrowse: () -> Unit,
    onCreate: () -> Unit,
    onBack: () -> Unit,
    viewModel: GroupListViewModel = hiltViewModel(),
) {
    val joinedGroups by viewModel.joinedGroups.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val colors = LocalNostrVaultColors.current

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Groups", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = onBrowse) {
                        Icon(NostrVaultIcons.Search, "Browse", tint = PrimaryText)
                    }
                    IconButton(onClick = onCreate) {
                        Icon(NostrVaultIcons.Create, "Create", tint = PrimaryText)
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
        } else if (joinedGroups.isEmpty()) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(
                        imageVector = NostrVaultIcons.Groups,
                        contentDescription = null,
                        tint = TertiaryText,
                        modifier = Modifier.size(48.dp),
                    )
                    Spacer(Modifier.height(12.dp))
                    Text("No groups joined", color = SecondaryText, fontSize = 16.sp)
                    Spacer(Modifier.height(8.dp))
                    TextButton(onClick = onBrowse) {
                        Text("Browse Groups", color = colors.primary)
                    }
                }
            }
        } else {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                items(joinedGroups, key = { "${it.groupId}_${it.relayURL}" }) { group ->
                    GroupRow(
                        group = group,
                        onClick = { onGroupClick(group.groupId, group.relayURL) },
                    )
                    HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
                }
            }
        }
    }
}

@Composable
private fun GroupRow(
    group: JoinedGroup,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        // Group icon placeholder
        Surface(
            color = LocalNostrVaultColors.current.primaryPale,
            shape = RoundedCornerShape(8.dp),
            modifier = Modifier.size(44.dp),
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    imageVector = NostrVaultIcons.Groups,
                    contentDescription = null,
                    tint = LocalNostrVaultColors.current.primary,
                    modifier = Modifier.size(22.dp),
                )
            }
        }

        Spacer(Modifier.width(12.dp))

        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = group.displayName ?: group.groupId,
                color = PrimaryText,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = group.relayURL.removePrefix("wss://"),
                color = SecondaryText,
                fontSize = 13.sp,
            )
        }

        Icon(
            imageVector = NostrVaultIcons.Navigate,
            contentDescription = null,
            tint = TertiaryText,
            modifier = Modifier.size(16.dp),
        )
    }
}
