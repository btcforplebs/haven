package com.nostrvault.ui.screens

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
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.GlassScaffold
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import coil.compose.AsyncImage
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.GlobalSearchResults
import com.nostrvault.service.NostrService
import com.nostrvault.ui.components.NoteCard
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * NIP-50 global search screen with profiles and notes results.
 */

enum class SearchResultFilter(val displayName: String) {
    ALL("All"),
    USERS("Users"),
    NOTES("Notes"),
    HASHTAGS("Hashtags"),
    LINKS("Links"),
}

enum class SearchScope(val displayName: String) {
    RELAY("Relay"),
    GLOBAL("Global"),
}

@HiltViewModel
class SearchViewModel @Inject constructor(
    private val nostrService: NostrService,
) : ViewModel() {

    private val _query = MutableStateFlow("")
    val query = _query.asStateFlow()

    private val _results = MutableStateFlow(GlobalSearchResults())
    val results = _results.asStateFlow()

    private val _isSearching = MutableStateFlow(false)
    val isSearching = _isSearching.asStateFlow()

    private val _resultFilter = MutableStateFlow(SearchResultFilter.ALL)
    val resultFilter = _resultFilter.asStateFlow()

    private val _searchScope = MutableStateFlow(SearchScope.RELAY)
    val searchScope = _searchScope.asStateFlow()

    val profiles = nostrService.profiles

    private var searchJob: Job? = null

    fun setQuery(text: String) {
        _query.value = text
        // Debounce search
        searchJob?.cancel()
        if (text.length >= 2) {
            searchJob = viewModelScope.launch {
                delay(400)
                performSearch(text)
            }
        } else {
            _results.value = GlobalSearchResults()
        }
    }

    fun setResultFilter(filter: SearchResultFilter) {
        _resultFilter.value = filter
    }

    fun setSearchScope(scope: SearchScope) {
        _searchScope.value = scope
    }

    private fun performSearch(query: String) {
        _isSearching.value = true
        nostrService.globalSearch(query) { results ->
            _results.value = results
            _isSearching.value = false
        }
    }

    fun profileFor(pubkey: String): FeedProfile? = profiles.value[pubkey]
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SearchScreen(
    onNoteClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    viewModel: SearchViewModel = hiltViewModel(),
) {
    val query by viewModel.query.collectAsState()
    val results by viewModel.results.collectAsState()
    val isSearching by viewModel.isSearching.collectAsState()
    val resultFilter by viewModel.resultFilter.collectAsState()
    val searchScope by viewModel.searchScope.collectAsState()
    val colors = LocalNostrVaultColors.current

    GlassScaffold(
        toolbar = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                // Toolbar pills row
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(bottom = 8.dp),
                ) {
                    // Leading pill: result type filter icons
                    GlassPill {
                        SearchResultFilter.entries.forEach { filter ->
                            val isSelected = filter == resultFilter
                            IconButton(
                                onClick = { viewModel.setResultFilter(filter) },
                                modifier = Modifier.size(40.dp),
                            ) {
                                Icon(
                                    imageVector = when (filter) {
                                        SearchResultFilter.ALL -> NostrVaultIcons.Layers
                                        SearchResultFilter.USERS -> NostrVaultIcons.Profile
                                        SearchResultFilter.NOTES -> NostrVaultIcons.Document
                                        SearchResultFilter.HASHTAGS -> NostrVaultIcons.TagIcon
                                        SearchResultFilter.LINKS -> NostrVaultIcons.LinkIcon
                                    },
                                    contentDescription = filter.displayName,
                                    tint = if (isSelected) colors.primary else SecondaryText,
                                    modifier = Modifier.size(25.dp),
                                )
                            }
                        }
                    }

                    Spacer(Modifier.weight(1f))

                    // Trailing pill: search scope (Relay / Global)
                    GlassPill {
                        SearchScope.entries.forEach { scope ->
                            val isSelected = scope == searchScope
                            IconButton(
                                onClick = { viewModel.setSearchScope(scope) },
                                modifier = Modifier.size(40.dp),
                            ) {
                                Icon(
                                    imageVector = when (scope) {
                                        SearchScope.RELAY -> NostrVaultIcons.Relay
                                        SearchScope.GLOBAL -> NostrVaultIcons.Globe
                                    },
                                    contentDescription = scope.displayName,
                                    tint = if (isSelected) colors.primary else SecondaryText,
                                    modifier = Modifier.size(25.dp),
                                )
                            }
                        }
                    }
                }

                // Search text field
                OutlinedTextField(
                    value = query,
                    onValueChange = viewModel::setQuery,
                    placeholder = { Text("Search Nostr...", color = PlaceholderText) },
                    leadingIcon = {
                        Icon(NostrVaultIcons.Search, null, tint = SecondaryText)
                    },
                    trailingIcon = {
                        if (query.isNotEmpty()) {
                            IconButton(onClick = { viewModel.setQuery("") }) {
                                Icon(NostrVaultIcons.Dismiss, "Clear", tint = SecondaryText)
                            }
                        }
                    },
                    singleLine = true,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = colors.primary,
                        unfocusedBorderColor = SeparatorColor,
                        cursorColor = colors.primary,
                    ),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
    ) { padding ->
        if (isSearching) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                CircularProgressIndicator(color = colors.primary)
            }
        } else if (query.length < 2) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(
                        imageVector = NostrVaultIcons.Search,
                        contentDescription = null,
                        tint = TertiaryText,
                        modifier = Modifier.size(48.dp),
                    )
                    Spacer(Modifier.height(12.dp))
                    Text(
                        text = "Search for people and notes",
                        color = SecondaryText,
                        fontSize = 16.sp,
                    )
                }
            }
        } else {
            LazyColumn(
                contentPadding = PaddingValues(
                    top = padding.calculateTopPadding(),
                    bottom = padding.calculateBottomPadding() + 88.dp,
                ),
                modifier = Modifier.fillMaxSize(),
            ) {
                // Profiles section
                if (results.profiles.isNotEmpty()) {
                    item {
                        Text(
                            text = "People",
                            color = SecondaryText,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                        )
                    }
                    items(results.profiles.take(10), key = { it.pubkey }) { profile ->
                        SearchProfileRow(
                            profile = profile,
                            onClick = { onProfileClick(profile.pubkey) },
                        )
                    }
                    item {
                        HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
                        Spacer(Modifier.height(8.dp))
                    }
                }

                // Notes section
                if (results.notes.isNotEmpty()) {
                    item {
                        Text(
                            text = "Notes",
                            color = SecondaryText,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                        )
                    }
                    items(results.notes, key = { it.id }) { note ->
                        NoteCard(
                            note = note,
                            profile = viewModel.profileFor(note.pubkey),
                            stats = null,
                            onNoteClick = onNoteClick,
                            onProfileClick = onProfileClick,
                        )
                        HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
                    }
                }

                // No results
                if (results.profiles.isEmpty() && results.notes.isEmpty()) {
                    item {
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(32.dp),
                        ) {
                            Text("No results found", color = SecondaryText, fontSize = 15.sp)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SearchProfileRow(
    profile: FeedProfile,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        AsyncImage(
            model = profile.pictureURL,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .size(44.dp)
                .clip(CircleShape),
        )
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = profile.bestName,
                color = PrimaryText,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            profile.nip05?.let {
                Text(text = it, color = SecondaryText, fontSize = 13.sp)
            }
            profile.about?.takeIf { it.isNotBlank() }?.let {
                Text(
                    text = it,
                    color = TertiaryText,
                    fontSize = 13.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}
