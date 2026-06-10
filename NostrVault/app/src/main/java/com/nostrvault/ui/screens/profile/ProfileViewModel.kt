package com.nostrvault.ui.screens.profile

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.NoteStats
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * ViewModel for a user's profile screen.
 * Loads profile data, notes, and follow state.
 */
enum class ProfileSection(val displayName: String) {
    NOTES("Notes"),
    MEDIA("Media"),
    REPLIES("Replies"),
}

@HiltViewModel
class ProfileViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val nostrService: NostrService,
    private val feedService: FeedService,
    private val configStore: ConfigStore,
) : ViewModel() {

    val pubkey: String = savedStateHandle["pubkey"] ?: ""

    val profile: StateFlow<FeedProfile?> = nostrService.profiles
        .map { it[pubkey] }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    private val _profileNotes = MutableStateFlow<List<FeedNote>>(emptyList())
    val profileNotes: StateFlow<List<FeedNote>> = _profileNotes.asStateFlow()

    val noteStats: StateFlow<Map<String, NoteStats>> = feedService.noteStats
    val likedEventIds: StateFlow<Set<String>> = feedService.likedEventIds
    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles

    private val _selectedSection = MutableStateFlow(ProfileSection.NOTES)
    val selectedSection: StateFlow<ProfileSection> = _selectedSection.asStateFlow()

    private val _isFollowing = MutableStateFlow(false)
    val isFollowing: StateFlow<Boolean> = _isFollowing.asStateFlow()

    private val _isOwnProfile = MutableStateFlow(false)
    val isOwnProfile: StateFlow<Boolean> = _isOwnProfile.asStateFlow()

    private val _followersCount = MutableStateFlow(0)
    val followersCount: StateFlow<Int> = _followersCount.asStateFlow()

    private val _followingCount = MutableStateFlow(0)
    val followingCount: StateFlow<Int> = _followingCount.asStateFlow()

    private val _isLoading = MutableStateFlow(true)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    val filteredNotes: StateFlow<List<FeedNote>> = combine(
        _profileNotes,
        _selectedSection,
    ) { notes, section ->
        when (section) {
            ProfileSection.NOTES -> notes.filter { !it.isReply }
            ProfileSection.MEDIA -> notes.filter { it.mediaURLs.isNotEmpty() && !it.isReply }
            ProfileSection.REPLIES -> notes.filter { it.isReply }
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    init {
        loadProfile()
    }

    private fun loadProfile() {
        viewModelScope.launch {
            _isLoading.value = true
            _isOwnProfile.value = pubkey == configStore.activeAccountHexPubkey.value

            // Fetch profile if not cached
            if (nostrService.profiles.value[pubkey] == null) {
                nostrService.fetchMissingProfiles(listOf(pubkey))
            }

            // Check follow state
            _isFollowing.value = feedService.isFollowing(pubkey)

            // Load notes for this profile
            nostrService.fetchProfileNotes(pubkey) { notes ->
                _profileNotes.value = notes.sortedByDescending { it.createdAt }
            }

            _isLoading.value = false
        }
    }

    fun setSection(section: ProfileSection) {
        _selectedSection.value = section
    }

    fun toggleFollow() {
        viewModelScope.launch {
            if (_isFollowing.value) {
                feedService.unfollowPubkey(pubkey)
            } else {
                feedService.followPubkey(pubkey)
            }
            _isFollowing.value = !_isFollowing.value
        }
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
}
