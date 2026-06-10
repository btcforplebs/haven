package com.nostrvault.ui.screens.groups

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import coil.compose.AsyncImage
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.GroupInfo
import com.nostrvault.service.GroupMember
import com.nostrvault.service.GroupService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Group info screen showing metadata, member list, and admin actions.
 */

@HiltViewModel
class GroupInfoViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val groupService: GroupService,
    private val nostrService: NostrService,
) : ViewModel() {

    val groupId: String = savedStateHandle["groupId"] ?: ""
    val relayUrl: String = savedStateHandle["relayUrl"] ?: ""

    private val _groupInfo = MutableStateFlow<GroupInfo?>(null)
    val groupInfo = _groupInfo.asStateFlow()

    private val _members = MutableStateFlow<List<GroupMember>>(emptyList())
    val members = _members.asStateFlow()

    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles

    private val _isLoading = MutableStateFlow(true)
    val isLoading = _isLoading.asStateFlow()

    init {
        viewModelScope.launch {
            _isLoading.value = true
            _groupInfo.value = groupService.getGroupInfo(groupId, relayUrl)
            _members.value = groupService.getGroupMembers(groupId, relayUrl)

            val pubkeys = _members.value.map { it.pubkey }
            nostrService.fetchMissingProfiles(pubkeys)
            _isLoading.value = false
        }
    }

    fun leaveGroup() {
        viewModelScope.launch {
            groupService.leaveGroup(groupId, relayUrl)
        }
    }

    fun profileFor(pubkey: String): FeedProfile? = profiles.value[pubkey]
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GroupInfoScreen(
    groupId: String,
    relayUrl: String,
    onProfileClick: (String) -> Unit,
    onBack: () -> Unit,
    viewModel: GroupInfoViewModel = hiltViewModel(),
) {
    val groupInfo by viewModel.groupInfo.collectAsState()
    val members by viewModel.members.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val colors = LocalNostrVaultColors.current

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Group Info") },
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
        } else {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                // Group header
                item {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(24.dp),
                    ) {
                        Surface(
                            color = colors.primaryPale,
                            shape = RoundedCornerShape(16.dp),
                            modifier = Modifier.size(72.dp),
                        ) {
                            Box(contentAlignment = Alignment.Center) {
                                Icon(
                                    imageVector = NostrVaultIcons.Groups,
                                    contentDescription = null,
                                    tint = colors.primary,
                                    modifier = Modifier.size(36.dp),
                                )
                            }
                        }
                        Spacer(Modifier.height(12.dp))
                        Text(
                            text = groupInfo?.name ?: groupId,
                            color = PrimaryText,
                            fontSize = 22.sp,
                            fontWeight = FontWeight.Bold,
                        )
                        Text(
                            text = relayUrl.removePrefix("wss://"),
                            color = SecondaryText,
                            fontSize = 14.sp,
                        )
                        groupInfo?.about?.takeIf { it.isNotBlank() }?.let {
                            Spacer(Modifier.height(8.dp))
                            Text(
                                text = it,
                                color = SecondaryText,
                                fontSize = 14.sp,
                            )
                        }
                    }
                }

                // Members header
                item {
                    Text(
                        text = "Members (${members.size})",
                        color = SecondaryText,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                }

                items(members, key = { it.pubkey }) { member ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onProfileClick(member.pubkey) }
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                    ) {
                        val profile = viewModel.profileFor(member.pubkey)
                        AsyncImage(
                            model = profile?.pictureURL,
                            contentDescription = null,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier
                                .size(36.dp)
                                .clip(CircleShape),
                        )
                        Spacer(Modifier.width(12.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = profile?.bestName ?: member.pubkey.take(8) + "...",
                                color = PrimaryText,
                                fontSize = 15.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            if (member.roles.isNotEmpty()) {
                                Text(
                                    text = member.roles.first(),
                                    color = colors.primary,
                                    fontSize = 12.sp,
                                )
                            }
                        }
                    }
                }

                // Leave group button
                item {
                    Spacer(Modifier.height(24.dp))
                    TextButton(
                        onClick = {
                            viewModel.leaveGroup()
                            onBack()
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp),
                    ) {
                        Text("Leave Group", color = ErrorRed)
                    }
                    Spacer(Modifier.height(32.dp))
                }
            }
        }
    }
}
