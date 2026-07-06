package com.nostrvault.ui.components

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Routes full-screen media viewing requests to a host composed at the activity
 * root (above the NavHost). The viewer must live in the activity window — not a
 * Dialog — because Picture-in-Picture only captures the activity's own window;
 * a Dialog-hosted video would vanish the moment PiP starts.
 */
object FullScreenMediaRouter {

    data class Request(val urls: List<String>, val initialIndex: Int)

    private val _request = MutableStateFlow<Request?>(null)
    val request = _request.asStateFlow()

    fun open(urls: List<String>, initialIndex: Int) {
        if (urls.isEmpty()) return
        _request.value = Request(urls, initialIndex)
    }

    fun dismiss() {
        _request.value = null
    }
}

/** Composed once in MainActivity above the NavHost; shows the pager when requested. */
@Composable
fun FullScreenMediaHost() {
    val request by FullScreenMediaRouter.request.collectAsState()
    request?.let {
        FullScreenMediaPager(
            urls = it.urls,
            initialIndex = it.initialIndex,
            onDismiss = FullScreenMediaRouter::dismiss,
        )
    }
}
