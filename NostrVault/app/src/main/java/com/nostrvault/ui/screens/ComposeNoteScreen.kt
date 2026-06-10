package com.nostrvault.ui.screens

import android.util.Log
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Compose new note screen with text input and publish action.
 * Supports replying to notes via NIP-10 e/p tags.
 */

@HiltViewModel
class ComposeNoteViewModel @Inject constructor(
    private val nostrService: NostrService,
    private val feedService: FeedService,
    savedStateHandle: SavedStateHandle,
) : ViewModel() {

    private val replyToNoteId: String? = savedStateHandle["replyTo"]

    private val _content = MutableStateFlow("")
    val content = _content.asStateFlow()

    private val _isPublishing = MutableStateFlow(false)
    val isPublishing = _isPublishing.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()

    /** Display name of the author being replied to (for UI hint). */
    private val _replyingToName = MutableStateFlow<String?>(null)
    val replyingToName = _replyingToName.asStateFlow()

    val isReply: Boolean get() = replyToNoteId != null

    init {
        if (replyToNoteId != null) {
            val parentNote = feedService.findNote(replyToNoteId)
            if (parentNote != null) {
                val profile = nostrService.profiles.value[parentNote.pubkey]
                _replyingToName.value = profile?.bestName ?: parentNote.pubkey.take(8) + "..."
            }
        }
    }

    fun setContent(text: String) { _content.value = text }

    fun publish(onPublished: () -> Unit) {
        val text = _content.value.trim()
        if (text.isBlank()) return

        viewModelScope.launch {
            _isPublishing.value = true
            _error.value = null
            try {
                val tags = buildReplyTags()
                val event = nostrService.signEventAsync(kind = 1, content = text, tags = tags)
                if (event != null) {
                    nostrService.postEvent(event)
                    onPublished()
                } else {
                    Log.e("ComposeNote", "signEventAsync returned null for kind=1")
                    _error.value = "Failed to sign note"
                }
            } catch (e: Exception) {
                Log.e("ComposeNote", "publish failed", e)
                _error.value = e.message ?: "Failed to publish"
            }
            _isPublishing.value = false
        }
    }

    /**
     * Build NIP-10 reply tags (e-tags with root/reply markers + p-tag for author).
     * Returns empty list for new top-level notes.
     */
    private fun buildReplyTags(): List<List<String>> {
        val parentId = replyToNoteId ?: return emptyList()
        val parentNote = feedService.findNote(parentId) ?: return emptyList()

        val tags = mutableListOf<List<String>>()

        // Determine thread structure from parent's tags
        val parentETags = parentNote.tags.filter { it.size >= 2 && it[0] == "e" }
        val parentNonMentionETags = parentETags.filter { it.size < 4 || it[3] != "mention" }

        if (parentNonMentionETags.isEmpty()) {
            // Parent IS the root note — single e-tag with "root" marker
            tags.add(listOf("e", parentId, "", "root"))
        } else {
            // Parent is itself a reply — find the thread root
            val rootTag = parentNonMentionETags.firstOrNull { it.size >= 4 && it[3] == "root" }
            val threadRootId = rootTag?.get(1) ?: parentNonMentionETags[0][1]
            tags.add(listOf("e", threadRootId, "", "root"))
            tags.add(listOf("e", parentId, "", "reply"))
        }

        // Always tag the parent author
        tags.add(listOf("p", parentNote.pubkey))

        return tags
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ComposeNoteScreen(
    replyToNoteId: String? = null,
    onPublished: () -> Unit,
    onBack: () -> Unit,
    viewModel: ComposeNoteViewModel = hiltViewModel(),
) {
    val content by viewModel.content.collectAsState()
    val isPublishing by viewModel.isPublishing.collectAsState()
    val error by viewModel.error.collectAsState()
    val replyingToName by viewModel.replyingToName.collectAsState()
    val colors = LocalNostrVaultColors.current

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(if (viewModel.isReply) "Reply" else "New Note") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Dismiss, contentDescription = "Cancel")
                    }
                },
                actions = {
                    Button(
                        onClick = { viewModel.publish(onPublished) },
                        enabled = content.isNotBlank() && !isPublishing,
                        colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                        shape = RoundedCornerShape(20.dp),
                        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 8.dp),
                    ) {
                        if (isPublishing) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(16.dp),
                                strokeWidth = 2.dp,
                                color = PrimaryText,
                            )
                        } else {
                            Text(
                                text = "Publish",
                                fontWeight = FontWeight.SemiBold,
                                color = PrimaryText,
                            )
                        }
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
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            // Reply context indicator
            replyingToName?.let { name ->
                Text(
                    text = "Replying to $name",
                    color = SecondaryText,
                    fontSize = 13.sp,
                )
                Spacer(Modifier.height(8.dp))
            }

            // Error message
            error?.let { errMsg ->
                Surface(
                    color = ErrorRed.copy(alpha = 0.1f),
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        text = errMsg,
                        color = ErrorRed,
                        fontSize = 14.sp,
                        modifier = Modifier.padding(12.dp),
                    )
                }
                Spacer(Modifier.height(12.dp))
            }

            // Text input
            OutlinedTextField(
                value = content,
                onValueChange = viewModel::setContent,
                placeholder = {
                    Text(
                        if (viewModel.isReply) "Write your reply..." else "What's on your mind?",
                        color = PlaceholderText,
                    )
                },
                minLines = 8,
                maxLines = 20,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = Color.Transparent,
                    unfocusedBorderColor = Color.Transparent,
                    cursorColor = colors.primary,
                ),
                modifier = Modifier.fillMaxWidth(),
            )

            Spacer(Modifier.height(16.dp))

            // Character count
            Text(
                text = "${content.length} characters",
                color = TertiaryText,
                fontSize = 12.sp,
                modifier = Modifier.align(Alignment.End),
            )
        }
    }
}
