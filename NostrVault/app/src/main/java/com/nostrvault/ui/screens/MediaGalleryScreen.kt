package com.nostrvault.ui.screens

import android.util.Log
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import coil.compose.AsyncImage
import coil.request.ImageRequest
import androidx.compose.ui.platform.LocalContext
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.*
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.GlassScaffold
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.util.concurrent.TimeUnit
import javax.inject.Inject

/**
 * Media gallery showing personal blossom content from local and external blossoms.
 * Port of MediaTabView.swift.
 */

@HiltViewModel
class MediaGalleryViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
    private val statsService: StatsService,
    private val mediaCacheService: MediaCacheService,
) : ViewModel() {

    private val _isLoading = MutableStateFlow(false)
    val isLoading = _isLoading.asStateFlow()

    private val _mediaItems = MutableStateFlow<List<BlossomMediaItem>>(emptyList())
    val mediaItems = _mediaItems.asStateFlow()

    private val json = Json { ignoreUnknownKeys = true }

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    init {
        loadBlossomMedia()
    }

    fun refresh() {
        loadBlossomMedia()
    }

    private fun loadBlossomMedia() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                withContext(Dispatchers.IO) {
                    val items = mutableMapOf<String, BlossomMediaItem>()

                    // 1. Scan local blossom directory
                    loadLocalBlossomFiles(items)

                    // 2. Fetch from local relay via BUD-04
                    val pubkey = nostrService.ownerHexPubkey
                    if (pubkey.isNotEmpty()) {
                        try {
                            val localBlobs = statsService.fetchBlobList(pubkey)
                            mergeBlobs(items, localBlobs, source = null)
                        } catch (e: Exception) {
                            Log.w(TAG, "Local relay blob list failed: ${e.message}")
                        }

                        // 3. Fetch from external mirrors in parallel
                        val mirrors = configStore.config.value.activeBlossomMirrors
                        coroutineScope {
                            mirrors.map { mirror ->
                                async {
                                    try {
                                        fetchMirrorBlobList(mirror, pubkey) to mirror
                                    } catch (e: Exception) {
                                        Log.w(TAG, "Mirror list from $mirror failed: ${e.message}")
                                        null
                                    }
                                }
                            }.awaitAll().filterNotNull().forEach { (blobs, source) ->
                                mergeBlobs(items, blobs, source = source)
                            }
                        }
                    }

                    _mediaItems.value = items.values
                        .filter { it.isImage || it.isVideo || it.mimeType == null }
                        .sortedByDescending { it.uploaded ?: (it.lastModified?.div(1000)) ?: 0L }
                        .toList()
                }
            } finally {
                _isLoading.value = false
            }
        }
    }

    private fun loadLocalBlossomFiles(items: MutableMap<String, BlossomMediaItem>) {
        val config = configStore.config.value
        val blossomDir = config.relayDataDir?.let { File(it, config.blossomPath) } ?: return
        if (!blossomDir.exists()) return

        blossomDir.listFiles()?.forEach { file ->
            if (!file.isFile) return@forEach
            val hash = file.nameWithoutExtension
            if (hash.length != 64 || !hash.all { it in "0123456789abcdef" }) return@forEach

            val fileType = statsService.detectFileType(file)

            items[hash] = BlossomMediaItem(
                sha256 = hash,
                displayUrl = file.absolutePath,
                localFile = file,
                mimeType = when (fileType) {
                    FileType.IMAGE -> "image"
                    FileType.VIDEO -> "video"
                    else -> null
                },
                size = file.length(),
                uploaded = null,
                lastModified = file.lastModified(),
                isLocal = true,
            )
        }
    }

    private fun mergeBlobs(
        items: MutableMap<String, BlossomMediaItem>,
        blobs: List<BlobDescriptor>,
        source: String?,
    ) {
        for (blob in blobs) {
            val hash = blob.sha256 ?: continue
            val existing = items[hash]
            if (existing != null) {
                // Merge metadata from server into existing local item
                items[hash] = existing.copy(
                    uploaded = blob.uploaded ?: existing.uploaded,
                    mimeType = blob.type ?: existing.mimeType,
                    size = blob.size ?: existing.size,
                )
            } else {
                // Remote-only item
                val url = blob.url ?: source?.let { "$it/$hash" } ?: continue
                items[hash] = BlossomMediaItem(
                    sha256 = hash,
                    displayUrl = url,
                    localFile = null,
                    mimeType = blob.type,
                    size = blob.size,
                    uploaded = blob.uploaded,
                    lastModified = null,
                    isLocal = false,
                )
            }
        }
    }

    private fun fetchMirrorBlobList(mirror: String, pubkey: String): List<BlobDescriptor> {
        val request = Request.Builder()
            .url("$mirror/list/$pubkey")
            .get()
            .build()

        val response = httpClient.newCall(request).execute()
        if (!response.isSuccessful) return emptyList()

        val body = response.body?.string() ?: return emptyList()
        return json.decodeFromString<List<BlobDescriptor>>(body)
    }

    companion object {
        private const val TAG = "MediaGalleryVM"
    }
}

/** Lightweight bridge so MediaViewerScreen can access the gallery's current filtered media list. */
object MediaGalleryBridge {
    var currentItems: List<BlossomMediaItem> = emptyList()
}

data class BlossomMediaItem(
    val sha256: String,
    val displayUrl: String,
    val localFile: File?,
    val mimeType: String?,
    val size: Long?,
    val uploaded: Long?,
    val lastModified: Long?,
    val isLocal: Boolean,
) {
    val isVideo: Boolean get() = mimeType?.startsWith("video") == true
    val isImage: Boolean get() = mimeType?.startsWith("image") == true || mimeType == "image"
}

data class MediaItem(val url: String, val noteId: String)

/** Media type filter matching iOS MediaTypeFilter. */
enum class MediaTypeFilter { ALL, PHOTO, VIDEO, GIF, OTHER }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MediaGalleryScreen(
    onMediaClick: (Int) -> Unit,
    onNoteClick: (String) -> Unit,
    onBlossomClick: () -> Unit,
    viewModel: MediaGalleryViewModel = hiltViewModel(),
) {
    val mediaItems by viewModel.mediaItems.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    var activeFilter by remember { mutableStateOf(MediaTypeFilter.ALL) }
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current

    val filteredItems = remember(mediaItems, activeFilter) {
        when (activeFilter) {
            MediaTypeFilter.ALL -> mediaItems
            MediaTypeFilter.PHOTO -> mediaItems.filter { it.isImage }
            MediaTypeFilter.VIDEO -> mediaItems.filter { it.isVideo }
            MediaTypeFilter.GIF -> mediaItems.filter {
                it.mimeType?.contains("gif", ignoreCase = true) == true
            }
            MediaTypeFilter.OTHER -> mediaItems.filter { !it.isImage && !it.isVideo }
        }
    }

    GlassScaffold(
        toolbar = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .statusBarsPadding(),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                ) {
                    // Leading: media type filter icons
                    GlassPill {
                        MediaFilterIcon(
                            icon = NostrVaultIcons.GridLayout,
                            label = "All",
                            selected = activeFilter == MediaTypeFilter.ALL,
                            accentColor = colors.primary,
                            onClick = { activeFilter = MediaTypeFilter.ALL },
                        )
                        MediaFilterIcon(
                            icon = NostrVaultIcons.Media,
                            label = "Photos",
                            selected = activeFilter == MediaTypeFilter.PHOTO,
                            accentColor = colors.primary,
                            onClick = { activeFilter = MediaTypeFilter.PHOTO },
                        )
                        MediaFilterIcon(
                            icon = NostrVaultIcons.Video,
                            label = "Videos",
                            selected = activeFilter == MediaTypeFilter.VIDEO,
                            accentColor = colors.primary,
                            onClick = { activeFilter = MediaTypeFilter.VIDEO },
                        )
                        MediaFilterIcon(
                            icon = NostrVaultIcons.Document,
                            label = "Other",
                            selected = activeFilter == MediaTypeFilter.OTHER,
                            accentColor = colors.primary,
                            onClick = { activeFilter = MediaTypeFilter.OTHER },
                        )
                    }

                    Spacer(Modifier.weight(1f))

                    // Trailing: layout toggle + upload
                    GlassPill {
                        IconButton(onClick = { /* grid/list toggle */ }, modifier = Modifier.size(40.dp)) {
                            Icon(
                                imageVector = NostrVaultIcons.GridLayout,
                                contentDescription = "Grid view",
                                tint = SecondaryText,
                                modifier = Modifier.size(25.dp),
                            )
                        }
                        IconButton(onClick = { /* upload media */ }, modifier = Modifier.size(40.dp)) {
                            Icon(
                                imageVector = NostrVaultIcons.Create,
                                contentDescription = "Upload",
                                tint = colors.primary,
                                modifier = Modifier.size(25.dp),
                            )
                        }
                    }
                }
            }
        },
        floatingActionButton = {
            Surface(
                onClick = onBlossomClick,
                modifier = Modifier.padding(bottom = 88.dp),
                color = colors.primary,
                shape = CircleShape,
                shadowElevation = 8.dp,
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(horizontal = 18.dp, vertical = 12.dp),
                ) {
                    Icon(
                        imageVector = NostrVaultIcons.Blossom,
                        contentDescription = null,
                        tint = PrimaryText,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        text = "Blossom",
                        color = PrimaryText,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Bold,
                    )
                }
            }
        },
    ) { padding ->
        PullToRefreshBox(
            isRefreshing = isLoading,
            onRefresh = { viewModel.refresh() },
            modifier = Modifier.fillMaxSize(),
        ) {
            if (filteredItems.isEmpty() && !isLoading) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(top = padding.calculateTopPadding()),
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Icon(
                            imageVector = NostrVaultIcons.Media,
                            contentDescription = null,
                            tint = TertiaryText,
                            modifier = Modifier.size(48.dp),
                        )
                        Spacer(Modifier.height(12.dp))
                        Text("No media yet", color = SecondaryText, fontSize = 16.sp)
                    }
                }
            } else {
                LazyVerticalGrid(
                    columns = GridCells.Fixed(3),
                    contentPadding = PaddingValues(
                        top = padding.calculateTopPadding() + 2.dp,
                        start = 2.dp,
                        end = 2.dp,
                        bottom = padding.calculateBottomPadding() + 88.dp,
                    ),
                    horizontalArrangement = Arrangement.spacedBy(2.dp),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    itemsIndexed(
                        items = filteredItems,
                        key = { _, item -> item.sha256 },
                    ) { index, item ->
                        AsyncImage(
                            model = ImageRequest.Builder(context)
                                .data(item.localFile ?: item.displayUrl)
                                .size(360, 360)
                                .crossfade(true)
                                .build(),
                            contentDescription = null,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier
                                .aspectRatio(1f)
                                .clip(RoundedCornerShape(2.dp))
                                .clickable {
                                    MediaGalleryBridge.currentItems = filteredItems
                                    onMediaClick(index)
                                },
                        )
                    }
                }
            }
        }
    }
}

/** Small icon button used in the media type filter toolbar. */
@Composable
private fun MediaFilterIcon(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    selected: Boolean,
    accentColor: androidx.compose.ui.graphics.Color,
    onClick: () -> Unit,
) {
    IconButton(onClick = onClick, modifier = Modifier.size(40.dp)) {
        Icon(
            imageVector = icon,
            contentDescription = label,
            tint = if (selected) accentColor else SecondaryText,
            modifier = Modifier.size(25.dp),
        )
    }
}
