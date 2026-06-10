package com.nostrvault.ui.screens.dm

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
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
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import coil.compose.AsyncImage
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.DMConversation
import com.nostrvault.service.DMService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.GlassScaffold
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * DM inbox showing all conversations, sorted by most recent message.
 * Port of DMInboxView.swift.
 */

@HiltViewModel
class DMInboxViewModel @Inject constructor(
    private val dmService: DMService,
    private val nostrService: NostrService,
) : ViewModel() {

    val conversations: StateFlow<List<DMConversation>> = dmService.conversations
    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles

    private val _isLoading = MutableStateFlow(true)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    init {
        viewModelScope.launch {
            dmService.loadConversations()
            _isLoading.value = false

            // Fetch profiles for all conversation participants
            val pubkeys = conversations.value.map { it.id }.distinct()
            nostrService.fetchMissingProfiles(pubkeys)
        }
    }

    fun profileFor(pubkey: String): FeedProfile? = profiles.value[pubkey]
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DMInboxScreen(
    onConversationClick: (String) -> Unit,
    viewModel: DMInboxViewModel = hiltViewModel(),
) {
    val conversations by viewModel.conversations.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val colors = LocalNostrVaultColors.current

    GlassScaffold(
        toolbar = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                // Leading pill: title
                GlassPill {
                    Text(
                        text = "Messages",
                        color = PrimaryText,
                        fontSize = 17.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(horizontal = 4.dp),
                    )
                }

                Spacer(Modifier.weight(1f))

                // Trailing pill: compose new message
                GlassPill {
                    IconButton(onClick = { /* mark all read */ }, modifier = Modifier.size(40.dp)) {
                        Icon(NostrVaultIcons.MarkAllRead, "Mark all read", tint = colors.primary, modifier = Modifier.size(25.dp))
                    }
                    IconButton(onClick = { /* new message */ }, modifier = Modifier.size(40.dp)) {
                        Icon(NostrVaultIcons.Edit, "New Message", tint = colors.primary, modifier = Modifier.size(25.dp))
                    }
                }
            }
        },
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
        } else if (conversations.isEmpty()) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(
                        imageVector = NostrVaultIcons.DMs,
                        contentDescription = null,
                        tint = TertiaryText,
                        modifier = Modifier.size(48.dp),
                    )
                    Spacer(Modifier.height(12.dp))
                    Text(
                        text = "No messages yet",
                        color = SecondaryText,
                        fontSize = 16.sp,
                    )
                }
            }
        } else {
            LazyColumn(
                contentPadding = padding,
                modifier = Modifier.fillMaxSize(),
            ) {
                items(
                    items = conversations,
                    key = { it.id },
                ) { conversation ->
                    ConversationRow(
                        conversation = conversation,
                        profile = viewModel.profileFor(conversation.id),
                        onClick = { onConversationClick(conversation.id) },
                    )
                    HorizontalDivider(
                        color = SeparatorColor,
                        thickness = 0.5.dp,
                        modifier = Modifier.padding(start = 72.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun ConversationRow(
    conversation: DMConversation,
    profile: FeedProfile?,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        AsyncImage(
            model = profile?.pictureURL,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .size(48.dp)
                .clip(CircleShape),
        )

        Spacer(Modifier.width(12.dp))

        Column(modifier = Modifier.weight(1f)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    text = profile?.bestName ?: conversation.id.take(8) + "...",
                    color = PrimaryText,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    text = formatRelativeTime((conversation.lastMessage?.timestamp ?: 0L) * 1000),
                    color = TertiaryText,
                    fontSize = 12.sp,
                )
            }

            Spacer(Modifier.height(2.dp))

            Text(
                text = conversation.lastMessage?.content ?: "",
                color = SecondaryText,
                fontSize = 14.sp,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }

        // Unread badge
        if (conversation.unreadCount > 0) {
            Spacer(Modifier.width(8.dp))
            Badge(
                containerColor = LocalNostrVaultColors.current.primary,
                contentColor = PrimaryText,
            ) {
                Text(
                    text = if (conversation.unreadCount > 99) "99+"
                    else conversation.unreadCount.toString(),
                    fontSize = 11.sp,
                )
            }
        }
    }
}

private fun formatRelativeTime(epochMs: Long): String {
    val now = System.currentTimeMillis()
    val diffSec = (now - epochMs) / 1000
    return when {
        diffSec < 60 -> "now"
        diffSec < 3600 -> "${diffSec / 60}m"
        diffSec < 86400 -> "${diffSec / 3600}h"
        diffSec < 604800 -> "${diffSec / 86400}d"
        else -> "${diffSec / 604800}w"
    }
}
