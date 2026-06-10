package com.nostrvault.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import coil.request.CachePolicy
import coil.request.ImageRequest

/**
 * Deterministic avatar with gradient placeholder, Coil downsampling, and error fallback.
 *
 * Replaces all bare AsyncImage avatar calls in the app. Key behaviors:
 * - Derives a stable gradient from the pubkey (same user = same color, always)
 * - Constrains Coil decode to 128px (sufficient for up to 80dp @ 3x density)
 * - Shows first letter of display name on the gradient while loading / on error
 * - Hardware bitmaps enabled (off-heap on Android, doesn't count against Java GC)
 */
@Composable
fun AvatarImage(
    url: String?,
    pubkey: String,
    size: Dp,
    modifier: Modifier = Modifier,
    displayName: String? = null,
    onClick: (() -> Unit)? = null,
) {
    val gradient = remember(pubkey) { avatarGradient(pubkey) }
    val letter = remember(displayName, pubkey) {
        val source = displayName?.firstOrNull()?.takeIf { it.isLetterOrDigit() }
            ?: pubkey.firstOrNull()
            ?: '?'
        source.uppercaseChar().toString()
    }
    // Scale font to avatar size: 40dp -> 14sp, 32dp -> 11sp, 80dp -> 26sp
    val fontSize = remember(size) { (size.value * 0.325f).sp }

    val context = LocalContext.current

    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .size(size)
            .clip(CircleShape)
            .background(gradient),
    ) {
        // Fallback letter (always rendered behind the image)
        Text(
            text = letter,
            color = Color.White,
            fontSize = fontSize,
            fontWeight = FontWeight.Bold,
        )

        // Actual image overlays the gradient+letter when loaded
        if (url != null) {
            AsyncImage(
                model = ImageRequest.Builder(context)
                    .data(url)
                    .size(128)
                    .memoryCachePolicy(CachePolicy.ENABLED)
                    .diskCachePolicy(CachePolicy.ENABLED)
                    .allowHardware(true)
                    .crossfade(150)
                    .build(),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .size(size)
                    .clip(CircleShape),
            )
        }
    }
}

// 8 fixed gradient pairs derived from existing theme palette.
// Deterministic: pubkey byte 0 selects the pair, same user = same color always.
private val avatarGradientPalette = listOf(
    Color(0xFF6B2D8F) to Color(0xFF8A4DB0), // purple
    Color(0xFF1773BD) to Color(0xFF3394E0), // blue
    Color(0xFF219469) to Color(0xFF38BA87), // green
    Color(0xFFE67326) to Color(0xFFFA9447), // orange
    Color(0xFFE03870) to Color(0xFFF25994), // pink
    Color(0xFF73808C) to Color(0xFF94A1AE), // slate
    Color(0xFF542370) to Color(0xFF6B2D8F), // deep purple
    Color(0xFF0D528C) to Color(0xFF1773BD), // deep blue
)

private fun avatarGradient(pubkey: String): Brush {
    // Use first hex char of pubkey to pick color (0-f -> 0-15, mod 8 -> 0-7)
    val index = pubkey.firstOrNull()?.digitToIntOrNull(16) ?: 0
    val (start, end) = avatarGradientPalette[index % avatarGradientPalette.size]
    return Brush.linearGradient(listOf(start, end))
}
