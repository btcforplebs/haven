package com.nostrvault.ui.screens.dm

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import coil.compose.AsyncImage
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.DMService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Compose a brand-new DM, picking a recipient by profile search or npub.
 * Port of MessageComposerView.swift (iOS new-message composer).
 */

@HiltViewModel
class NewMessageViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val dmService: DMService,
    private val nostrService: NostrService,
) : ViewModel() {

    /** Optional pre-locked recipient (e.g. opened from a profile). null = free picker. */
    val lockedRecipient: String? = savedStateHandle["pubkey"]

    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles

    private val _selectedRecipient = MutableStateFlow(lockedRecipient)
    val selectedRecipient: StateFlow<String?> = _selectedRecipient.asStateFlow()

    private val _searchText = MutableStateFlow("")
    val searchText: StateFlow<String> = _searchText.asStateFlow()

    private val _messageText = MutableStateFlow("")
    val messageText: StateFlow<String> = _messageText.asStateFlow()

    private val _isSending = MutableStateFlow(false)
    val isSending: StateFlow<Boolean> = _isSending.asStateFlow()

    /** Search results: npub decode (single hit) or name/pubkey substring filter (cap 10). */
    val searchResults: StateFlow<List<String>> =
        combine(_searchText, nostrService.profiles) { query, profs ->
            val q = query.trim()
            if (q.length < 2) return@combine emptyList()
            val lower = q.lowercase()

            if (lower.startsWith("npub1")) {
                HavenBridge.decodeNpub(q)?.let { return@combine listOf(it) }
            }

            profs.keys.filter { pubkey ->
                val name = profs[pubkey]?.bestName ?: ""
                name.lowercase().contains(lower) || pubkey.lowercase().contains(lower)
            }.take(10)
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val canSend: StateFlow<Boolean> =
        combine(_messageText, _selectedRecipient) { msg, recipient ->
            msg.trim().isNotEmpty() && recipient != null
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    init {
        viewModelScope.launch {
            lockedRecipient?.let { nostrService.fetchMissingProfiles(listOf(it)) }
        }
    }

    fun profileFor(pubkey: String): FeedProfile? = profiles.value[pubkey]

    fun setSearchText(text: String) { _searchText.value = text }

    fun selectRecipient(pubkey: String) {
        _selectedRecipient.value = pubkey
        _searchText.value = ""
        viewModelScope.launch { nostrService.fetchMissingProfiles(listOf(pubkey)) }
    }

    /** Recipient can only be cleared when it wasn't pre-locked. */
    fun clearRecipient() {
        if (lockedRecipient == null) _selectedRecipient.value = null
    }

    fun setMessageText(text: String) { _messageText.value = text }

    fun send(onSent: (String) -> Unit) {
        val recipient = _selectedRecipient.value ?: return
        val content = _messageText.value.trim()
        if (content.isEmpty() || _isSending.value) return

        viewModelScope.launch {
            _isSending.value = true
            dmService.sendDM(content, recipient)
            _isSending.value = false
            onSent(recipient)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NewMessageScreen(
    onMessageSent: (String) -> Unit,
    onBack: () -> Unit,
    viewModel: NewMessageViewModel = hiltViewModel(),
) {
    val selectedRecipient by viewModel.selectedRecipient.collectAsState()
    val searchText by viewModel.searchText.collectAsState()
    val searchResults by viewModel.searchResults.collectAsState()
    val messageText by viewModel.messageText.collectAsState()
    val isSending by viewModel.isSending.collectAsState()
    val canSend by viewModel.canSend.collectAsState()
    val colors = LocalNostrVaultColors.current

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("New Message") },
                navigationIcon = {
                    TextButton(onClick = onBack) {
                        Text("Cancel", color = colors.primary)
                    }
                },
                actions = {
                    if (isSending) {
                        CircularProgressIndicator(
                            modifier = Modifier
                                .padding(end = 16.dp)
                                .size(20.dp),
                            strokeWidth = 2.dp,
                            color = colors.primary,
                        )
                    } else {
                        TextButton(
                            onClick = { viewModel.send(onMessageSent) },
                            enabled = canSend,
                        ) {
                            Text(
                                "Send",
                                color = if (canSend) colors.primary else TertiaryText,
                                fontWeight = FontWeight.SemiBold,
                            )
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = WindowBackground,
                    titleContentColor = PrimaryText,
                ),
            )
        },
        containerColor = WindowBackground,
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            val recipient = selectedRecipient
            if (recipient != null) {
                RecipientChip(
                    pubkey = recipient,
                    profile = viewModel.profileFor(recipient),
                    canClear = viewModel.lockedRecipient == null,
                    onClear = { viewModel.clearRecipient() },
                )
            } else {
                RecipientSearchField(
                    searchText = searchText,
                    onSearchChange = viewModel::setSearchText,
                )
                LazyColumn(modifier = Modifier.weight(1f, fill = false)) {
                    items(items = searchResults, key = { it }) { pubkey ->
                        SearchResultRow(
                            pubkey = pubkey,
                            profile = viewModel.profileFor(pubkey),
                            onClick = { viewModel.selectRecipient(pubkey) },
                        )
                    }
                }
            }

            HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)

            OutlinedTextField(
                value = messageText,
                onValueChange = viewModel::setMessageText,
                placeholder = { Text("Write a message...", color = PlaceholderText) },
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = colors.primary,
                    unfocusedBorderColor = SeparatorColor,
                    cursorColor = colors.primary,
                ),
                shape = RoundedCornerShape(16.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 120.dp)
                    .padding(16.dp),
            )
        }
    }
}

@Composable
private fun RecipientSearchField(
    searchText: String,
    onSearchChange: (String) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Text("To:", color = SecondaryText, fontSize = 15.sp)
        Spacer(Modifier.width(10.dp))
        OutlinedTextField(
            value = searchText,
            onValueChange = onSearchChange,
            placeholder = { Text("Search users...", color = PlaceholderText) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = colors.primary,
                unfocusedBorderColor = SeparatorColor,
                cursorColor = colors.primary,
            ),
            shape = RoundedCornerShape(20.dp),
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun SearchResultRow(
    pubkey: String,
    profile: FeedProfile?,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        AsyncImage(
            model = profile?.pictureURL,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .size(40.dp)
                .clip(CircleShape),
        )
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = profile?.bestName ?: pubkey.take(8),
                color = PrimaryText,
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = pubkey.take(12) + "…",
                color = TertiaryText,
                fontSize = 12.sp,
                fontFamily = FontFamily.Monospace,
            )
        }
    }
}

@Composable
private fun RecipientChip(
    pubkey: String,
    profile: FeedProfile?,
    canClear: Boolean,
    onClear: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        Text("To:", color = SecondaryText, fontSize = 15.sp)
        Spacer(Modifier.width(10.dp))
        AsyncImage(
            model = profile?.pictureURL,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .size(32.dp)
                .clip(CircleShape),
        )
        Spacer(Modifier.width(8.dp))
        Text(
            text = profile?.bestName ?: pubkey.take(8) + "…",
            color = PrimaryText,
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (canClear) {
            IconButton(onClick = onClear, modifier = Modifier.size(28.dp)) {
                Icon(
                    imageVector = NostrVaultIcons.Dismiss,
                    contentDescription = "Clear recipient",
                    tint = TertiaryText,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}
