package com.nostrvault.ui.screens

import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.layout.IntrinsicSize
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
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.NoteStats
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.GlassScaffold
import com.nostrvault.ui.components.MediaPreviewRow
import com.nostrvault.ui.components.NoteCard
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.*
import javax.inject.Inject

/**
 * Thread view for a single note with parent chain, nested replies,
 * tap-to-focus navigation, and depth-based collapsing.
 * Port of NoteDetailView.swift.
 */

@HiltViewModel
class NoteDetailViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val nostrService: NostrService,
    private val feedService: FeedService,
) : ViewModel() {

    val noteId: String = savedStateHandle["noteId"] ?: ""

    private val _note = MutableStateFlow<FeedNote?>(null)
    val note: StateFlow<FeedNote?> = _note.asStateFlow()

    private val _parentNotes = MutableStateFlow<List<FeedNote>>(emptyList())
    val parentNotes: StateFlow<List<FeedNote>> = _parentNotes.asStateFlow()

    /** All replies in the thread (flat list used to build the tree). */
    private val _allReplies = MutableStateFlow<List<FeedNote>>(emptyList())
    val allReplies: StateFlow<List<FeedNote>> = _allReplies.asStateFlow()

    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles
    val noteStats: StateFlow<Map<String, NoteStats>> = feedService.noteStats
    val likedEventIds: StateFlow<Set<String>> = feedService.likedEventIds

    private val _isLoading = MutableStateFlow(true)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _isCompact = MutableStateFlow(false)
    val isCompact: StateFlow<Boolean> = _isCompact.asStateFlow()

    init {
        loadNoteThread()
    }

    private fun loadNoteThread() {
        viewModelScope.launch {
            _isLoading.value = true

            val foundNote = feedService.findNote(noteId)
            _note.value = foundNote

            if (foundNote != null) {
                // Load parent chain
                val parents = mutableListOf<FeedNote>()
                var currentParentId = foundNote.parentEventId
                while (currentParentId != null) {
                    val parent = feedService.findNote(currentParentId)
                    if (parent != null) {
                        parents.add(0, parent)
                        currentParentId = parent.parentEventId
                    } else {
                        break
                    }
                }
                _parentNotes.value = parents

                // Load replies
                nostrService.fetchReplies(noteId) { replyNotes ->
                    _allReplies.value = replyNotes.sortedBy { it.createdAt }
                }

                val pubkeys = (parents.map { it.pubkey } + foundNote.pubkey).distinct()
                nostrService.fetchMissingProfiles(pubkeys)
            }

            _isLoading.value = false
        }
    }

    fun toggleCompact() {
        _isCompact.value = !_isCompact.value
    }

    fun likeNote(noteId: String) {
        viewModelScope.launch { feedService.likeNote(noteId) }
    }

    fun repostNote(noteId: String) {
        viewModelScope.launch { feedService.repostNote(noteId) }
    }

    fun profileFor(pubkey: String): FeedProfile? = profiles.value[pubkey]
    fun statsFor(noteId: String): NoteStats? = noteStats.value[noteId]
    fun isLiked(noteId: String): Boolean = likedEventIds.value.contains(noteId)

    /** Get direct child replies for a given note ID. */
    fun childRepliesFor(parentId: String): List<FeedNote> =
        _allReplies.value.filter { it.parentEventId == parentId }
}

// ── Screen ──────────────────────────────────────────────────────

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NoteDetailScreen(
    noteId: String,
    onProfileClick: (String) -> Unit,
    onNoteClick: (String) -> Unit,
    onReply: (String) -> Unit,
    onBack: () -> Unit,
    viewModel: NoteDetailViewModel = hiltViewModel(),
) {
    val note by viewModel.note.collectAsState()
    val parentNotes by viewModel.parentNotes.collectAsState()
    val allReplies by viewModel.allReplies.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val isCompact by viewModel.isCompact.collectAsState()
    val colors = LocalNostrVaultColors.current
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()

    // The currently focused note (hero). Starts as the original note,
    // tapping a parent or reply refocuses the thread around it.
    var focusedNoteId by remember { mutableStateOf(noteId) }

    // Derive focused note, parents, and direct replies from focusedNoteId
    val focusedNote = remember(focusedNoteId, note, allReplies) {
        if (focusedNoteId == noteId) note
        else allReplies.find { it.id == focusedNoteId }
            ?: parentNotes.find { it.id == focusedNoteId }
            ?: note
    }

    val dynamicParents = remember(focusedNoteId, parentNotes, note) {
        if (focusedNoteId == noteId) {
            parentNotes
        } else {
            // Build parent chain up to focusedNoteId
            val chain = mutableListOf<FeedNote>()
            val allNotes = parentNotes + listOfNotNull(note) + allReplies
            var currentId: String? = allNotes.find { it.id == focusedNoteId }?.parentEventId
            while (currentId != null) {
                val parent = allNotes.find { it.id == currentId }
                if (parent != null) {
                    chain.add(0, parent)
                    currentId = parent.parentEventId
                } else break
            }
            chain
        }
    }

    val directReplies = remember(focusedNoteId, allReplies, note) {
        val heroId = focusedNote?.id ?: noteId
        allReplies.filter { it.parentEventId == heroId }.sortedBy { it.createdAt }
    }

    // Auto-scroll to hero after loading
    LaunchedEffect(isLoading) {
        if (!isLoading && note != null) {
            // Small delay for layout to settle
            kotlinx.coroutines.delay(200)
            val heroKey = "hero_${focusedNoteId}"
            val idx = listState.layoutInfo.totalItemsCount.let { total ->
                (0 until total).firstOrNull { i ->
                    listState.layoutInfo.visibleItemsInfo.any { it.key == heroKey }
                }
            }
            // Scroll so hero is roughly centered
            val parentCount = dynamicParents.size
            if (parentCount > 0) {
                listState.animateScrollToItem(parentCount, scrollOffset = -100)
            }
        }
    }

    fun scrollToNote(targetId: String) {
        focusedNoteId = targetId
        scope.launch {
            kotlinx.coroutines.delay(100)
            val parentCount = dynamicParents.size
            listState.animateScrollToItem(parentCount, scrollOffset = -100)
        }
    }

    GlassScaffold(
        toolbar = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                // Leading pill: back button
                GlassPill {
                    IconButton(onClick = onBack, modifier = Modifier.size(40.dp)) {
                        Icon(NostrVaultIcons.Back, "Back", tint = PrimaryText, modifier = Modifier.size(25.dp))
                    }
                }

                Spacer(Modifier.weight(1f))

                // Trailing pill: compact toggle + stats + reply + broadcast
                GlassPill {
                    // Compact view toggle
                    IconButton(
                        onClick = viewModel::toggleCompact,
                        modifier = Modifier.size(40.dp),
                    ) {
                        Icon(
                            imageVector = if (isCompact) NostrVaultIcons.CompactView else NostrVaultIcons.ExpandedView,
                            contentDescription = if (isCompact) "Expanded view" else "Compact view",
                            tint = if (isCompact) colors.primary else SecondaryText,
                            modifier = Modifier.size(25.dp),
                        )
                    }
                    // Thread stats toggle
                    IconButton(onClick = { /* toggle thread stats */ }, modifier = Modifier.size(40.dp)) {
                        Icon(NostrVaultIcons.BarChart, "Thread Stats", tint = SecondaryText, modifier = Modifier.size(25.dp))
                    }
                    // Reply
                    IconButton(onClick = { focusedNote?.let { onReply(it.id) } }, modifier = Modifier.size(40.dp)) {
                        Icon(NostrVaultIcons.Reply, "Reply", tint = SecondaryText, modifier = Modifier.size(25.dp))
                    }
                    // Broadcast
                    IconButton(onClick = { /* broadcast */ }, modifier = Modifier.size(40.dp)) {
                        Icon(NostrVaultIcons.Relay, "Broadcast", tint = SecondaryText, modifier = Modifier.size(25.dp))
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
        } else if (focusedNote == null) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                Text("Note not found", color = SecondaryText, fontSize = 16.sp)
            }
        } else {
            LazyColumn(
                state = listState,
                contentPadding = padding,
                modifier = Modifier.fillMaxSize(),
            ) {
                // ── Parent chain ────────────────────────────────
                items(dynamicParents, key = { it.id }) { parent ->
                    if (isCompact) {
                        CompactParentRow(
                            note = parent,
                            profile = viewModel.profileFor(parent.pubkey),
                            isFocused = parent.id == focusedNoteId,
                            themeColor = colors.primary,
                            onClick = { scrollToNote(parent.id) },
                        )
                    } else {
                        NoteCard(
                            note = parent,
                            profile = viewModel.profileFor(parent.pubkey),
                            stats = viewModel.statsFor(parent.id),
                            isLiked = viewModel.isLiked(parent.id),
                            parentIsNext = true,
                            onNoteClick = { scrollToNote(parent.id) },
                            onProfileClick = onProfileClick,
                            onLike = viewModel::likeNote,
                        )
                    }
                    // Thread connector line
                    ThreadConnectorLine(color = colors.primary)
                }

                // ── Hero note ───────────────────────────────────
                item(key = "hero_${focusedNote!!.id}") {
                    HeroNoteCard(
                        note = focusedNote!!,
                        profile = viewModel.profileFor(focusedNote!!.pubkey),
                        stats = viewModel.statsFor(focusedNote!!.id),
                        isLiked = viewModel.isLiked(focusedNote!!.id),
                        themeColor = colors.primary,
                        onProfileClick = onProfileClick,
                        onLike = { viewModel.likeNote(focusedNote!!.id) },
                        onRepost = { viewModel.repostNote(focusedNote!!.id) },
                        onReply = { onReply(focusedNote!!.id) },
                    )
                }

                // ── Replies header ──────────────────────────────
                if (directReplies.isNotEmpty()) {
                    item {
                        Text(
                            text = "${directReplies.size} ${if (directReplies.size == 1) "Reply" else "Replies"}",
                            color = SecondaryText,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                        )
                    }
                }

                // ── Threaded replies ────────────────────────────
                items(directReplies, key = { it.id }) { reply ->
                    ThreadedReplyNode(
                        reply = reply,
                        depth = 1,
                        isCompact = isCompact,
                        themeColor = colors.primary,
                        viewModel = viewModel,
                        onProfileClick = onProfileClick,
                        onNoteClick = onNoteClick,
                        onFocus = { id -> scrollToNote(id) },
                    )
                }

                // Bottom spacer
                item { Spacer(Modifier.height(32.dp)) }
            }
        }
    }
}

// ── Thread connector line ───────────────────────────────────────

@Composable
private fun ThreadConnectorLine(color: androidx.compose.ui.graphics.Color) {
    Box(
        modifier = Modifier
            .padding(start = 36.dp)
            .width(1.5.dp)
            .height(12.dp)
            .background(color.copy(alpha = 0.25f)),
    )
}

// ── Compact parent row ──────────────────────────────────────────

@Composable
private fun CompactParentRow(
    note: FeedNote,
    profile: FeedProfile?,
    isFocused: Boolean,
    themeColor: androidx.compose.ui.graphics.Color,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .then(
                if (isFocused) Modifier.border(
                    1.dp, themeColor.copy(alpha = 0.5f), RoundedCornerShape(8.dp)
                ) else Modifier
            )
            .padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        AsyncImage(
            model = profile?.pictureURL,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .size(28.dp)
                .clip(CircleShape),
        )
        Spacer(Modifier.width(8.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = profile?.bestName ?: note.pubkey.take(8) + "...",
                color = PrimaryText,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = note.content,
                color = SecondaryText,
                fontSize = 12.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

// ── Threaded reply node (recursive) ─────────────────────────────

private const val MAX_INDENT_DEPTH = 5
private const val COLLAPSE_DEPTH = 3

@Composable
private fun ThreadedReplyNode(
    reply: FeedNote,
    depth: Int,
    isCompact: Boolean,
    themeColor: androidx.compose.ui.graphics.Color,
    viewModel: NoteDetailViewModel,
    onProfileClick: (String) -> Unit,
    onNoteClick: (String) -> Unit,
    onFocus: (String) -> Unit,
) {
    val childReplies = remember(reply.id) { viewModel.childRepliesFor(reply.id) }
    val indentDp = (minOf(depth - 1, MAX_INDENT_DEPTH) * 16).dp

    Column(
        modifier = Modifier
            .padding(start = indentDp)
            .animateContentSize(animationSpec = spring()),
    ) {
        // The reply itself
        if (isCompact) {
            CompactParentRow(
                note = reply,
                profile = viewModel.profileFor(reply.pubkey),
                isFocused = false,
                themeColor = themeColor,
                onClick = { onFocus(reply.id) },
            )
        } else {
            NoteCard(
                note = reply,
                profile = viewModel.profileFor(reply.pubkey),
                stats = viewModel.statsFor(reply.id),
                isLiked = viewModel.isLiked(reply.id),
                onNoteClick = { onFocus(reply.id) },
                onProfileClick = onProfileClick,
                onLike = viewModel::likeNote,
            )
        }

        // Child replies
        if (childReplies.isNotEmpty()) {
            if (depth >= COLLAPSE_DEPTH && !isCompact) {
                // Collapse deep threads to a "Show X more" button
                TextButton(
                    onClick = { onFocus(reply.id) },
                    modifier = Modifier.padding(start = 16.dp, top = 4.dp, bottom = 4.dp),
                ) {
                    Icon(
                        imageVector = NostrVaultIcons.Navigate,
                        contentDescription = null,
                        tint = themeColor,
                        modifier = Modifier.size(14.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        text = "Show ${childReplies.size} more ${if (childReplies.size == 1) "reply" else "replies"}",
                        color = themeColor,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            } else {
                // Render children with connector line
                Row(modifier = Modifier.padding(start = 8.dp).height(IntrinsicSize.Min)) {
                    // Vertical connector line
                    Box(
                        modifier = Modifier
                            .width(1.5.dp)
                            .fillMaxHeight()
                            .background(themeColor.copy(alpha = 0.25f)),
                    )
                    Spacer(Modifier.width(6.dp))
                    Column {
                        for (child in childReplies) {
                            ThreadedReplyNode(
                                reply = child,
                                depth = depth + 1,
                                isCompact = isCompact,
                                themeColor = themeColor,
                                viewModel = viewModel,
                                onProfileClick = onProfileClick,
                                onNoteClick = onNoteClick,
                                onFocus = onFocus,
                            )
                        }
                    }
                }
            }
        }
    }
}

// ── Hero note card ──────────────────────────────────────────────

@Composable
private fun HeroNoteCard(
    note: FeedNote,
    profile: FeedProfile?,
    stats: NoteStats?,
    isLiked: Boolean,
    themeColor: androidx.compose.ui.graphics.Color,
    onProfileClick: (String) -> Unit,
    onLike: () -> Unit,
    onRepost: () -> Unit,
    onReply: () -> Unit,
) {
    val dateFormat = remember { SimpleDateFormat("MMM d, yyyy 'at' h:mm a", Locale.getDefault()) }

    Surface(
        color = WindowBackground,
        shape = RoundedCornerShape(12.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, themeColor.copy(alpha = 0.3f)),
        shadowElevation = 2.dp,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            // Author header
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.clickable { onProfileClick(note.pubkey) },
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
                Column {
                    Text(
                        text = profile?.bestName ?: note.pubkey.take(8) + "...",
                        color = PrimaryText,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    profile?.nip05?.let {
                        Text(text = it, color = SecondaryText, fontSize = 13.sp)
                    }
                }
            }

            Spacer(Modifier.height(16.dp))

            // Content
            if (note.content.isNotBlank()) {
                Text(
                    text = note.content,
                    color = PrimaryText,
                    fontSize = 17.sp,
                    lineHeight = 24.sp,
                )
                Spacer(Modifier.height(12.dp))
            }

            // Media
            if (note.mediaURLs.isNotEmpty()) {
                MediaPreviewRow(urls = note.mediaURLs)
                Spacer(Modifier.height(12.dp))
            }

            // Full timestamp
            Text(
                text = dateFormat.format(note.createdAt),
                color = TertiaryText,
                fontSize = 13.sp,
            )

            Spacer(Modifier.height(12.dp))
            HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
            Spacer(Modifier.height(12.dp))

            // Engagement stats row
            Row(
                horizontalArrangement = Arrangement.SpaceEvenly,
                modifier = Modifier.fillMaxWidth(),
            ) {
                EngagementStat(count = stats?.reactions ?: 0, label = "Likes")
                EngagementStat(count = stats?.reposts ?: 0, label = "Reposts")
                EngagementStat(count = stats?.zaps ?: 0, label = "Zaps")
            }

            Spacer(Modifier.height(12.dp))
            HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
            Spacer(Modifier.height(8.dp))

            // Action buttons
            Row(
                horizontalArrangement = Arrangement.SpaceEvenly,
                modifier = Modifier.fillMaxWidth(),
            ) {
                IconButton(onClick = onReply) {
                    Icon(NostrVaultIcons.Reply, "Reply", tint = SecondaryText)
                }
                IconButton(onClick = onRepost) {
                    Icon(NostrVaultIcons.Repost, "Repost", tint = SecondaryText)
                }
                IconButton(onClick = onLike) {
                    Icon(
                        imageVector = if (isLiked) NostrVaultIcons.HeartFilled else NostrVaultIcons.Heart,
                        contentDescription = "Like",
                        tint = if (isLiked) LikeRed else SecondaryText,
                    )
                }
                IconButton(onClick = {}) {
                    Icon(NostrVaultIcons.Zap, "Zap", tint = SecondaryText)
                }
                IconButton(onClick = {}) {
                    Icon(NostrVaultIcons.Share, "Share", tint = SecondaryText)
                }
            }
        }
    }
}

@Composable
private fun EngagementStat(count: Int, label: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = count.toString(),
            color = PrimaryText,
            fontSize = 15.sp,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.width(4.dp))
        Text(
            text = label,
            color = SecondaryText,
            fontSize = 14.sp,
        )
    }
}
