package com.nostrvault.ui.components

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.snapshotFlow

/**
 * Drives the bottom-bar + FAB condense animation from a scrollable list's
 * first-visible position (iOS parity with FeedService.feedScrollingDown).
 *
 * Performance: this writes [setScrollingDown] ONLY on a direction *flip* (never
 * per-frame), with an 8px threshold to debounce jitter, and force-expands at the
 * very top. Because the resulting flag is read only by the bottom bar + FABs
 * (never by a list row), a flip never recomposes the list — no scroll-jank.
 * Resets to expanded when the host leaves composition (i.e. on tab switch).
 *
 * Works for both LazyListState and LazyGridState — pass their
 * firstVisibleItemIndex / firstVisibleItemScrollOffset as lambdas.
 *
 * @param scrollKey re-arms the snapshot loop when the underlying scroll source
 *   changes (e.g. the media grid/list toggle swaps which state is observed).
 */
@Composable
fun ScrollCondenseEffect(
    scrollKey: Any?,
    firstVisibleItemIndex: () -> Int,
    firstVisibleItemScrollOffset: () -> Int,
    setScrollingDown: (Boolean) -> Unit,
) {
    LaunchedEffect(scrollKey) {
        var lastIndex = firstVisibleItemIndex()
        var lastOffset = firstVisibleItemScrollOffset()
        var scrollingDown = false
        snapshotFlow { firstVisibleItemIndex() to firstVisibleItemScrollOffset() }
            .collect { (index, offset) ->
                if (index == 0 && offset < 8) {
                    // At the very top → always expanded.
                    if (scrollingDown) {
                        scrollingDown = false
                        setScrollingDown(false)
                    }
                } else {
                    val down = if (index != lastIndex) index > lastIndex else offset - lastOffset > 8
                    val up = if (index != lastIndex) index < lastIndex else lastOffset - offset > 8
                    if (down && !scrollingDown) {
                        scrollingDown = true
                        setScrollingDown(true)
                    } else if (up && scrollingDown) {
                        scrollingDown = false
                        setScrollingDown(false)
                    }
                }
                lastIndex = index
                lastOffset = offset
            }
    }
    DisposableEffect(Unit) {
        onDispose { setScrollingDown(false) }
    }
}
