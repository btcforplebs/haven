package com.nostrvault.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import coil.compose.AsyncImage
import com.nostrvault.data.model.ArticleMeta
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.jeziellago.compose.markdowntext.MarkdownText
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.text.DateFormat
import javax.inject.Inject

/**
 * Reader for one NIP-23 long-form post.
 *
 * A kind-30023 body is Markdown, and rendering it as the plain text a kind-1
 * note gets would show the reader the syntax instead of the article. The
 * markdown renderer was already a dependency of this project and was not being
 * used anywhere.
 */
@HiltViewModel
class ArticleReaderViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val feedService: FeedService,
    private val nostrService: NostrService,
) : ViewModel() {

    val noteId: String = savedStateHandle["noteId"] ?: ""

    private val _note = MutableStateFlow<FeedNote?>(null)
    val note: StateFlow<FeedNote?> = _note.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles

    init {
        // Same two-step the note screen uses: the in-memory feed first, then
        // the relays, so an article opened from a link rather than from the
        // list still resolves.
        val cached = feedService.findNote(noteId)
        if (cached != null) {
            _note.value = cached
        } else {
            _isLoading.value = true
            nostrService.fetchNoteById(noteId, onRawEvent = feedService::cacheRawEvent) { fetched ->
                _isLoading.value = false
                if (fetched != null) {
                    _note.value = fetched
                    feedService.cacheNote(fetched)
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ArticleReaderScreen(
    onBack: () -> Unit,
    onProfileClick: (String) -> Unit,
    viewModel: ArticleReaderViewModel = hiltViewModel(),
) {
    val note by viewModel.note.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    val colors = LocalNostrVaultColors.current

    Scaffold(
        containerColor = WindowBackground,
        topBar = {
            TopAppBar(
                title = { Text("Article", color = PrimaryText, fontSize = 17.sp) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back", tint = colors.primary)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = WindowBackground),
            )
        },
    ) { padding ->
        val current = note
        when {
            current != null -> ArticleBody(
                note = current,
                author = profiles[current.pubkey],
                onProfileClick = onProfileClick,
                modifier = Modifier
                    .padding(padding)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 20.dp),
            )
            isLoading -> Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.fillMaxSize().padding(padding),
            ) { CircularProgressIndicator(color = colors.primary) }
            else -> Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.fillMaxSize().padding(padding),
            ) {
                Text(
                    "That article is not in your vault, and no relay answered for it.",
                    color = SecondaryText,
                    fontSize = 14.sp,
                )
            }
        }
    }
}

@Composable
private fun ArticleBody(
    note: FeedNote,
    author: FeedProfile?,
    onProfileClick: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val meta = remember(note.id, note.tags) { ArticleMeta.from(note) }
    val colors = LocalNostrVaultColors.current

    Column(modifier = modifier) {
        Spacer(Modifier.height(8.dp))
        meta.imageUrl?.let { url ->
            AsyncImage(
                model = url,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(180.dp)
                    .clip(RoundedCornerShape(12.dp)),
            )
            Spacer(Modifier.height(16.dp))
        }
        Text(
            text = meta.title,
            color = PrimaryText,
            fontSize = 24.sp,
            fontWeight = FontWeight.Bold,
            lineHeight = 30.sp,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = buildString {
                append(author?.bestName ?: note.pubkey.take(8))
                append(" · ")
                append(DateFormat.getDateInstance(DateFormat.MEDIUM).format(meta.publishedAt))
            },
            color = SecondaryText,
            fontSize = 13.sp,
            modifier = Modifier.clickable { onProfileClick(note.pubkey) },
        )
        meta.summary?.let {
            Spacer(Modifier.height(12.dp))
            Text(it, color = SecondaryText, fontSize = 15.sp, lineHeight = 21.sp)
        }
        Spacer(Modifier.height(20.dp))
        MarkdownText(
            markdown = note.content,
            style = TextStyle(color = PrimaryText, fontSize = 16.sp, lineHeight = 24.sp),
            linkColor = colors.primary,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(48.dp))
    }
}
