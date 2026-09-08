package com.nostrvault.ui.screens.groups

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import coil.compose.AsyncImage
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.GroupMessage
import com.nostrvault.service.GroupService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.components.NostrMentions
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.*
import javax.inject.Inject

/**
 * Group chat screen with message list and input.
 * Port of GroupChatView.swift.
 */

@HiltViewModel
class GroupChatViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val groupService: GroupService,
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
) : ViewModel() {

    val groupId: String = savedStateHandle["groupId"] ?: ""
    val relayUrl: String = savedStateHandle["relayUrl"] ?: ""

    val messages: StateFlow<List<GroupMessage>> = groupService.messagesForGroup(groupId, relayUrl)
    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles
    val myPubkey: String get() = configStore.activeAccountHexPubkey.value

    private val _messageText = MutableStateFlow("")
    val messageText = _messageText.asStateFlow()

    private val _isSending = MutableStateFlow(false)
    val isSending = _isSending.asStateFlow()

    private val _groupName = MutableStateFlow("")
    val groupName = _groupName.asStateFlow()

    init {
        viewModelScope.launch {
            groupService.connectToGroup(groupId, relayUrl)
            val info = groupService.getGroupInfo(groupId, relayUrl)
            _groupName.value = info?.name ?: groupId
        }
    }

    fun setMessageText(text: String) { _messageText.value = text }

    fun sendMessage() {
        val text = _messageText.value.trim()
        if (text.isBlank() || _isSending.value) return

        viewModelScope.launch {
            _isSending.value = true
            _messageText.value = ""
            groupService.sendMessage(groupId, relayUrl, text)
            _isSending.value = false
        }
    }

    fun profileFor(pubkey: String): FeedProfile? = profiles.value[pubkey]
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GroupChatScreen(
    groupId: String,
    relayUrl: String,
    onInfo: () -> Unit,
    onProfileClick: (String) -> Unit,
    onBack: () -> Unit,
    viewModel: GroupChatViewModel = hiltViewModel(),
) {
    val messages by viewModel.messages.collectAsState()
    val messageText by viewModel.messageText.collectAsState()
    val isSending by viewModel.isSending.collectAsState()
    val groupName by viewModel.groupName.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    val listState = rememberLazyListState()
    val colors = LocalNostrVaultColors.current

    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) {
            listState.animateScrollToItem(messages.size - 1)
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(
                            text = groupName,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            text = relayUrl.removePrefix("wss://"),
                            color = SecondaryText,
                            fontSize = 12.sp,
                        )
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = onInfo) {
                        Icon(NostrVaultIcons.Info, "Info", tint = PrimaryText)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = WindowBackground,
                    titleContentColor = PrimaryText,
                    navigationIconContentColor = PrimaryText,
                ),
            )
        },
        bottomBar = {
            GroupMessageInput(
                text = messageText,
                isSending = isSending,
                onTextChange = viewModel::setMessageText,
                onSend = viewModel::sendMessage,
            )
        },
        containerColor = WindowBackground,
    ) { padding ->
        if (messages.isEmpty()) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                Text("No messages yet", color = SecondaryText, fontSize = 15.sp)
            }
        } else {
            LazyColumn(
                state = listState,
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                items(messages, key = { it.id }) { message ->
                    GroupMessageRow(
                        message = message,
                        profile = viewModel.profileFor(message.senderPubkey),
                        profiles = profiles,
                        isFromMe = message.senderPubkey == viewModel.myPubkey,
                        onProfileClick = onProfileClick,
                    )
                }
            }
        }
    }
}

@Composable
private fun GroupMessageRow(
    message: GroupMessage,
    profile: FeedProfile?,
    profiles: Map<String, FeedProfile>,
    isFromMe: Boolean,
    onProfileClick: (String) -> Unit,
) {
    val timeFormat = remember { SimpleDateFormat("h:mm a", Locale.getDefault()) }

    Row(
        modifier = Modifier.fillMaxWidth(),
    ) {
        if (!isFromMe) {
            AsyncImage(
                model = profile?.pictureURL,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .size(32.dp)
                    .clip(CircleShape),
            )
            Spacer(Modifier.width(8.dp))
        } else {
            Spacer(Modifier.weight(1f))
        }

        Column(
            horizontalAlignment = if (isFromMe) Alignment.End else Alignment.Start,
        ) {
            if (!isFromMe) {
                Text(
                    text = profile?.bestName ?: message.senderPubkey.take(8) + "...",
                    color = LocalNostrVaultColors.current.primary,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }

            Surface(
                color = if (isFromMe) {
                    LocalNostrVaultColors.current.primary.copy(alpha = 0.15f)
                } else {
                    SecondaryGroupedBg
                },
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.widthIn(max = 280.dp),
            ) {
                Column(modifier = Modifier.padding(10.dp)) {
                    Text(
                        text = remember(message.content, profiles) {
                            NostrMentions.toPlainText(message.content, profiles, stripQuoteRefs = false)
                        },
                        color = PrimaryText,
                        fontSize = 15.sp,
                    )
                    Text(
                        text = timeFormat.format(Date(message.timestamp * 1000)),
                        color = TertiaryText,
                        fontSize = 10.sp,
                    )
                }
            }
        }

        if (isFromMe) {
            // No trailing space needed
        } else {
            Spacer(Modifier.weight(1f))
        }
    }
}

@Composable
private fun GroupMessageInput(
    text: String,
    isSending: Boolean,
    onTextChange: (String) -> Unit,
    onSend: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current

    Surface(
        color = SecondaryGroupedBg,
        tonalElevation = 2.dp,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(horizontal = 12.dp, vertical = 8.dp),
        ) {
            OutlinedTextField(
                value = text,
                onValueChange = onTextChange,
                placeholder = { Text("Message", color = PlaceholderText) },
                maxLines = 4,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = colors.primary,
                    unfocusedBorderColor = SeparatorColor,
                    cursorColor = colors.primary,
                ),
                shape = RoundedCornerShape(20.dp),
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(8.dp))
            IconButton(
                onClick = onSend,
                enabled = text.isNotBlank() && !isSending,
            ) {
                Icon(
                    imageVector = NostrVaultIcons.Send,
                    contentDescription = "Send",
                    tint = if (text.isNotBlank()) colors.primary else TertiaryText,
                )
            }
        }
    }
}
