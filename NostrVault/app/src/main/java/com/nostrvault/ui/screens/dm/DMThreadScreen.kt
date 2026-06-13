package com.nostrvault.ui.screens.dm

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import coil.compose.AsyncImage
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.DMMessage
import com.nostrvault.service.DMService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.*
import javax.inject.Inject

/**
 * Individual DM conversation thread.
 * Port of DMThreadView.swift.
 */

@HiltViewModel
class DMThreadViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val dmService: DMService,
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
) : ViewModel() {

    val counterpartyPubkey: String = savedStateHandle["pubkey"] ?: ""

    val messages: StateFlow<List<DMMessage>> = dmService.messagesForConversation(counterpartyPubkey)

    val counterpartyProfile: StateFlow<FeedProfile?> = nostrService.profiles
        .map { it[counterpartyPubkey] }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    val myPubkey: String get() = configStore.activeAccountHexPubkey.value

    /** Whether this conversation already contains any NIP-04 (legacy) messages. */
    val hasNIP04Messages: StateFlow<Boolean> = messages
        .map { msgs -> msgs.any { it.isNIP04 } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    /** Selected send protocol. false = NIP-17 (default, encrypted), true = NIP-04 (legacy). */
    private val _useNIP04 = MutableStateFlow(false)
    val useNIP04 = _useNIP04.asStateFlow()

    private val _messageText = MutableStateFlow("")
    val messageText = _messageText.asStateFlow()

    private val _isSending = MutableStateFlow(false)
    val isSending = _isSending.asStateFlow()

    init {
        viewModelScope.launch {
            nostrService.fetchMissingProfiles(listOf(counterpartyPubkey))
            dmService.markConversationRead(counterpartyPubkey)
        }
    }

    fun setMessageText(text: String) { _messageText.value = text }

    fun toggleProtocol() { _useNIP04.value = !_useNIP04.value }

    fun sendMessage() {
        val text = _messageText.value.trim()
        if (text.isBlank() || _isSending.value) return

        viewModelScope.launch {
            _isSending.value = true
            _messageText.value = ""
            dmService.sendMessage(counterpartyPubkey, text, _useNIP04.value)
            _isSending.value = false
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DMThreadScreen(
    counterpartyPubkey: String,
    onProfileClick: (String) -> Unit,
    onBack: () -> Unit,
    viewModel: DMThreadViewModel = hiltViewModel(),
) {
    val messages by viewModel.messages.collectAsState()
    val counterpartyProfile by viewModel.counterpartyProfile.collectAsState()
    val messageText by viewModel.messageText.collectAsState()
    val isSending by viewModel.isSending.collectAsState()
    val useNIP04 by viewModel.useNIP04.collectAsState()
    val hasNIP04Messages by viewModel.hasNIP04Messages.collectAsState()
    val listState = rememberLazyListState()
    val colors = LocalNostrVaultColors.current

    // Scroll to bottom on new messages
    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) {
            listState.animateScrollToItem(messages.size - 1)
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.clickable { onProfileClick(counterpartyPubkey) },
                    ) {
                        AsyncImage(
                            model = counterpartyProfile?.pictureURL,
                            contentDescription = null,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier
                                .size(32.dp)
                                .clip(CircleShape),
                        )
                        Spacer(Modifier.width(10.dp))
                        Text(
                            text = counterpartyProfile?.bestName
                                ?: counterpartyPubkey.take(8) + "...",
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                },
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
        bottomBar = {
            Column {
                ProtocolToggleRow(
                    useNIP04 = useNIP04,
                    onToggle = viewModel::toggleProtocol,
                )
                MessageInputBar(
                    text = messageText,
                    isSending = isSending,
                    onTextChange = viewModel::setMessageText,
                    onSend = viewModel::sendMessage,
                )
            }
        },
        containerColor = WindowBackground,
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            if (hasNIP04Messages) {
                NIP04WarningBanner()
            }

            if (messages.isEmpty()) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier.fillMaxSize(),
                ) {
                    Text(
                        text = "Start a conversation",
                        color = SecondaryText,
                        fontSize = 15.sp,
                    )
                }
            } else {
                LazyColumn(
                    state = listState,
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    items(
                        items = messages,
                        key = { it.id },
                    ) { message ->
                        MessageBubble(
                            message = message,
                            isFromMe = message.senderPubkey == viewModel.myPubkey,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun NIP04WarningBanner() {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .fillMaxWidth()
            .background(ZapOrange.copy(alpha = 0.08f))
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Icon(
            imageVector = NostrVaultIcons.Alert,
            contentDescription = null,
            tint = ZapOrange.copy(alpha = 0.9f),
            modifier = Modifier.size(13.dp),
        )
        Text(
            text = "Some messages use NIP-04 (legacy encryption). New messages default to NIP-17.",
            color = ZapOrange.copy(alpha = 0.9f),
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
        )
    }
}

@Composable
private fun ProtocolToggleRow(
    useNIP04: Boolean,
    onToggle: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    Surface(color = WindowBackground) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 6.dp),
        ) {
            Icon(
                imageVector = if (useNIP04) NostrVaultIcons.LockOpen else NostrVaultIcons.Lock,
                contentDescription = null,
                tint = if (useNIP04) ZapOrange.copy(alpha = 0.8f) else colors.primary.copy(alpha = 0.7f),
                modifier = Modifier.size(12.dp),
            )
            Text(
                text = if (useNIP04) "NIP-04 (legacy)" else "NIP-17 (encrypted)",
                color = SecondaryText.copy(alpha = 0.8f),
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
            )
            Spacer(Modifier.weight(1f))
            Text(
                text = "Switch",
                color = colors.primary,
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.clickable(onClick = onToggle),
            )
        }
    }
}

@Composable
private fun MessageBubble(
    message: DMMessage,
    isFromMe: Boolean,
) {
    val colors = LocalNostrVaultColors.current
    val timeFormat = remember { SimpleDateFormat("h:mm a", Locale.getDefault()) }

    Column(
        horizontalAlignment = if (isFromMe) Alignment.End else Alignment.Start,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Surface(
            color = if (isFromMe) colors.primary.copy(alpha = 0.15f) else SecondaryGroupedBg,
            shape = RoundedCornerShape(
                topStart = 16.dp,
                topEnd = 16.dp,
                bottomStart = if (isFromMe) 16.dp else 4.dp,
                bottomEnd = if (isFromMe) 4.dp else 16.dp,
            ),
            modifier = Modifier.widthIn(max = 280.dp),
        ) {
            Column(modifier = Modifier.padding(12.dp)) {
                Text(
                    text = message.content,
                    color = PrimaryText,
                    fontSize = 15.sp,
                    lineHeight = 20.sp,
                )
                if (message.isNIP04) {
                    Spacer(Modifier.height(4.dp))
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(3.dp),
                    ) {
                        Icon(
                            imageVector = NostrVaultIcons.LockOpen,
                            contentDescription = null,
                            tint = ZapOrange.copy(alpha = 0.8f),
                            modifier = Modifier.size(10.dp),
                        )
                        Text(
                            text = "NIP-04",
                            color = ZapOrange.copy(alpha = 0.8f),
                            fontSize = 10.sp,
                            fontWeight = FontWeight.Medium,
                        )
                    }
                }
                Spacer(Modifier.height(4.dp))
                Text(
                    text = timeFormat.format(Date(message.timestamp * 1000)),
                    color = TertiaryText,
                    fontSize = 11.sp,
                )
            }
        }
    }
}

@Composable
private fun MessageInputBar(
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
                if (isSending) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(20.dp),
                        strokeWidth = 2.dp,
                        color = colors.primary,
                    )
                } else {
                    Icon(
                        imageVector = NostrVaultIcons.Send,
                        contentDescription = "Send",
                        tint = if (text.isNotBlank()) colors.primary else TertiaryText,
                    )
                }
            }
        }
    }
}
