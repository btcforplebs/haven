package com.nostrvault.ui.screens

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.net.toUri
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.nostrvault.service.MediaSaveService
import com.nostrvault.ui.components.VideoPlayer
import com.nostrvault.ui.components.ZoomableImage
import com.nostrvault.ui.notification.NotificationManager
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject
import kotlin.math.abs
import kotlin.math.max

@HiltViewModel
class MediaViewerViewModel @Inject constructor(
    private val mediaSaveService: MediaSaveService,
    private val notificationManager: NotificationManager,
) : ViewModel() {

    fun saveToGallery(item: BlossomMediaItem) {
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                if (item.localFile != null) {
                    mediaSaveService.saveToGallery(item.localFile, item.mimeType)
                } else {
                    mediaSaveService.saveToGallery(item.displayUrl, item.mimeType)
                }
            }
            if (result.isSuccess) {
                notificationManager.showToast("Saved to gallery")
            } else {
                notificationManager.showError("Save failed: ${result.exceptionOrNull()?.message}")
            }
        }
    }
}

/**
 * Full-screen media viewer with horizontal paging, pinch-to-zoom,
 * drag-to-dismiss, and single-ExoPlayer memory guard.
 *
 * Reads the current media list from [MediaGalleryBridge].
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MediaViewerScreen(
    initialIndex: Int,
    onBack: () -> Unit,
    autoplayVideos: Boolean = true,
    viewModel: MediaViewerViewModel = hiltViewModel(),
) {
    val items = remember { MediaGalleryBridge.currentItems }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current

    if (items.isEmpty()) {
        LaunchedEffect(Unit) { onBack() }
        return
    }

    val safeIndex = initialIndex.coerceIn(0, items.lastIndex)
    val pagerState = rememberPagerState(
        initialPage = safeIndex,
        pageCount = { items.size },
    )

    // Drag-to-dismiss state
    val dragOffsetY = remember { Animatable(0f) }
    var currentScale by remember { mutableFloatStateOf(1f) }

    // Derived visual properties matching iOS formulas
    val backgroundAlpha by remember {
        derivedStateOf {
            (0.9f * (1f - abs(dragOffsetY.value) / 300f)).coerceIn(0f, 0.9f)
        }
    }
    val contentScale by remember {
        derivedStateOf {
            max(0.8f, 1f - abs(dragOffsetY.value) / 1000f)
        }
    }
    val overlayAlpha by remember {
        derivedStateOf {
            (1f - abs(dragOffsetY.value) / 100f).coerceIn(0f, 1f)
        }
    }

    // Dismiss threshold in pixels (120dp)
    val dismissThresholdPx = with(density) { 120.dp.toPx() }

    // Accumulated vertical drag for ZoomableImage callback
    var accumulatedDragY by remember { mutableFloatStateOf(0f) }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = backgroundAlpha)),
    ) {
        HorizontalPager(
            state = pagerState,
            userScrollEnabled = currentScale <= 1.05f,
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer {
                    translationY = dragOffsetY.value
                    scaleX = contentScale
                    scaleY = contentScale
                },
        ) { page ->
            val item = items[page]

            if (item.isVideo) {
                // Only create ExoPlayer for the currently visible page
                // to keep memory usage at one instance (~10-15MB)
                if (page == pagerState.currentPage) {
                    val videoUri = item.localFile?.toUri()?.toString() ?: item.displayUrl
                    VideoPlayer(
                        uri = videoUri,
                        modifier = Modifier.fillMaxSize(),
                        autoplay = autoplayVideos,
                    )
                } else {
                    // Static thumbnail placeholder for off-screen video pages
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .fillMaxSize()
                            .background(Color.Black),
                    ) {
                        AsyncImage(
                            model = ImageRequest.Builder(context)
                                .data(item.localFile ?: item.displayUrl)
                                .crossfade(true)
                                .build(),
                            contentDescription = null,
                            contentScale = ContentScale.Fit,
                            modifier = Modifier.fillMaxSize(),
                        )
                        Icon(
                            imageVector = NostrVaultIcons.PlayCircle,
                            contentDescription = "Video",
                            tint = Color.White.copy(alpha = 0.85f),
                            modifier = Modifier.size(48.dp),
                        )
                    }
                }
            } else {
                ZoomableImage(
                    model = item.localFile ?: item.displayUrl,
                    contentDescription = null,
                    onScaleChanged = { newScale ->
                        currentScale = newScale
                    },
                    onVerticalDrag = { deltaY ->
                        if (currentScale <= 1.05f) {
                            accumulatedDragY += deltaY
                            scope.launch {
                                dragOffsetY.snapTo(accumulatedDragY)
                            }
                        }
                    },
                    onVerticalDragEnd = {
                        if (abs(accumulatedDragY) > dismissThresholdPx) {
                            onBack()
                        } else {
                            scope.launch {
                                dragOffsetY.animateTo(
                                    0f,
                                    spring(dampingRatio = 0.6f, stiffness = 400f),
                                )
                            }
                        }
                        accumulatedDragY = 0f
                    },
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }

        // Close button (fades during drag)
        IconButton(
            onClick = onBack,
            modifier = Modifier
                .align(Alignment.TopStart)
                .statusBarsPadding()
                .padding(8.dp)
                .graphicsLayer { alpha = overlayAlpha },
        ) {
            Icon(
                imageVector = NostrVaultIcons.Dismiss,
                contentDescription = "Close",
                tint = Color.White,
            )
        }

        // Save button (fades during drag)
        IconButton(
            onClick = {
                val currentItem = items.getOrNull(pagerState.currentPage)
                currentItem?.let { viewModel.saveToGallery(it) }
            },
            modifier = Modifier
                .align(Alignment.TopEnd)
                .statusBarsPadding()
                .padding(8.dp)
                .graphicsLayer { alpha = overlayAlpha },
        ) {
            Icon(
                imageVector = NostrVaultIcons.Import,
                contentDescription = "Save to gallery",
                tint = Color.White,
            )
        }

        // Page indicator (fades during drag)
        if (items.size > 1) {
            Text(
                text = "${pagerState.currentPage + 1} / ${items.size}",
                color = Color.White.copy(alpha = 0.7f),
                fontSize = 14.sp,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .navigationBarsPadding()
                    .padding(16.dp)
                    .graphicsLayer { alpha = overlayAlpha },
            )
        }
    }
}
