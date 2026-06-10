package com.nostrvault.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.URL

/**
 * OpenGraph link preview card shown below note content for the first non-media URL.
 *
 * Fetches OG metadata (title, description, image, siteName) via HTML meta tags.
 * Layout: 72dp image | title (13sp bold, 2 lines) + description (12sp, 2 lines) + domain (10sp).
 * Cached in a companion-level map to avoid repeated fetches.
 */
@Composable
fun LinkPreviewCard(
    url: String,
    modifier: Modifier = Modifier,
) {
    val colors = LocalNostrVaultColors.current
    val uriHandler = LocalUriHandler.current
    var metadata by remember(url) { mutableStateOf(ogMetadataCache[url]) }
    var fetched by remember(url) { mutableStateOf(ogMetadataCache.containsKey(url)) }

    // Fetch OG metadata on first composition
    LaunchedEffect(url) {
        if (!fetched) {
            fetched = true
            val result = fetchOgMetadata(url)
            ogMetadataCache[url] = result
            metadata = result
        }
    }

    val meta = metadata ?: return

    // Don't render if no meaningful metadata was found
    if (meta.title.isNullOrBlank() && meta.description.isNullOrBlank() && meta.imageUrl.isNullOrBlank()) return

    Surface(
        shape = RoundedCornerShape(8.dp),
        color = TertiaryGroupedBg,
        border = BorderStroke(0.5.dp, colors.primary.copy(alpha = 0.12f)),
        modifier = modifier
            .fillMaxWidth()
            .clickable {
                try { uriHandler.openUri(url) } catch (_: Exception) {}
            },
    ) {
        Row(
            verticalAlignment = Alignment.Top,
            modifier = Modifier.padding(10.dp),
        ) {
            // Image thumbnail
            if (!meta.imageUrl.isNullOrBlank()) {
                AsyncImage(
                    model = meta.imageUrl,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .size(72.dp)
                        .clip(RoundedCornerShape(6.dp)),
                )
                Spacer(Modifier.width(10.dp))
            }

            Column(modifier = Modifier.weight(1f)) {
                // Title
                if (!meta.title.isNullOrBlank()) {
                    Text(
                        text = meta.title!!,
                        color = PrimaryText,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 13.sp,
                        lineHeight = 17.sp,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }

                // Description
                if (!meta.description.isNullOrBlank()) {
                    if (!meta.title.isNullOrBlank()) Spacer(Modifier.height(2.dp))
                    Text(
                        text = meta.description!!,
                        color = SecondaryText,
                        fontSize = 12.sp,
                        lineHeight = 16.sp,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }

                // Domain
                Spacer(Modifier.height(2.dp))
                Text(
                    text = meta.siteName ?: extractDomain(url),
                    color = TertiaryText,
                    fontSize = 10.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

// ── OG Metadata ──────────────────────────────────────────────────

data class OgMetadata(
    val title: String?,
    val description: String?,
    val imageUrl: String?,
    val siteName: String?,
)

/** Simple in-memory cache for OG metadata. */
private val ogMetadataCache = mutableMapOf<String, OgMetadata>()

private fun extractDomain(url: String): String {
    return try {
        URL(url).host.removePrefix("www.")
    } catch (_: Exception) {
        url.removePrefix("https://").removePrefix("http://").substringBefore("/")
    }
}

/**
 * Fetch OpenGraph metadata from a URL by parsing HTML meta tags.
 * Returns an OgMetadata with whatever could be extracted.
 */
private suspend fun fetchOgMetadata(url: String): OgMetadata = withContext(Dispatchers.IO) {
    try {
        val connection = URL(url).openConnection().apply {
            setRequestProperty("User-Agent", "NostrVault/1.0")
            connectTimeout = 5000
            readTimeout = 5000
        }

        val html = connection.getInputStream().bufferedReader().use { reader ->
            val sb = StringBuilder()
            val buf = CharArray(4096)
            var total = 0
            while (total < 32_768) { // Read max 32KB
                val n = reader.read(buf)
                if (n < 0) break
                sb.append(buf, 0, n)
                total += n
                // Stop early if we've passed </head>
                if (sb.contains("</head>", ignoreCase = true)) break
            }
            sb.toString()
        }

        val title = extractMetaContent(html, "og:title")
            ?: extractMetaContent(html, "twitter:title")
            ?: extractHtmlTitle(html)
        val description = extractMetaContent(html, "og:description")
            ?: extractMetaContent(html, "twitter:description")
        val imageUrl = extractMetaContent(html, "og:image")
            ?: extractMetaContent(html, "twitter:image")
        val siteName = extractMetaContent(html, "og:site_name")

        OgMetadata(title, description, imageUrl, siteName)
    } catch (_: Exception) {
        OgMetadata(null, null, null, null)
    }
}

private val META_REGEX = Regex(
    """<meta[^>]*(?:property|name)=["']([^"']+)["'][^>]*content=["']([^"']+)["']""",
    setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
)
private val META_REGEX_REVERSE = Regex(
    """<meta[^>]*content=["']([^"']+)["'][^>]*(?:property|name)=["']([^"']+)["']""",
    setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
)
private val TITLE_REGEX = Regex(
    """<title[^>]*>([^<]+)</title>""",
    RegexOption.IGNORE_CASE,
)

private fun extractMetaContent(html: String, property: String): String? {
    for (match in META_REGEX.findAll(html)) {
        if (match.groupValues[1].equals(property, ignoreCase = true)) {
            return match.groupValues[2].trim().takeIf { it.isNotBlank() }
        }
    }
    for (match in META_REGEX_REVERSE.findAll(html)) {
        if (match.groupValues[2].equals(property, ignoreCase = true)) {
            return match.groupValues[1].trim().takeIf { it.isNotBlank() }
        }
    }
    return null
}

private fun extractHtmlTitle(html: String): String? {
    return TITLE_REGEX.find(html)?.groupValues?.get(1)?.trim()?.takeIf { it.isNotBlank() }
}
