package com.nostrvault.service

import android.util.Log
import android.util.LruCache
import kotlinx.coroutines.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * OpenGraph link preview metadata fetcher with multi-layer caching.
 * Memory cache → disk cache → network fetch with request coalescing.
 *
 * Port of LinkPreviewService.swift.
 */
@Singleton
class LinkPreviewService @Inject constructor() {

    companion object {
        private const val TAG = "LinkPreviewService"
        private const val MEMORY_CACHE_SIZE = 200
        private const val DISK_CACHE_EXPIRY_DAYS = 7
        private const val MAX_HTML_BYTES = 50 * 1024 // First 50KB
        private const val BROWSER_USER_AGENT =
            "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

        // OG tag regex patterns (handles both attribute orders)
        private val OG_PROPERTY_REGEX = Regex(
            """<meta\s+property="og:(\w+)"\s+content="([^"]*)"[^>]*>""",
            RegexOption.IGNORE_CASE,
        )
        private val OG_CONTENT_FIRST_REGEX = Regex(
            """<meta\s+content="([^"]*)"\s+property="og:(\w+)"[^>]*>""",
            RegexOption.IGNORE_CASE,
        )
        private val TITLE_REGEX = Regex(
            """<title[^>]*>([^<]+)</title>""",
            RegexOption.IGNORE_CASE,
        )
    }

    private val json = Json { ignoreUnknownKeys = true }
    private val memoryCache = LruCache<String, LinkPreviewMetadata>(MEMORY_CACHE_SIZE)
    private val failedURLs = ConcurrentHashMap.newKeySet<String>()
    private val inFlightRequests = ConcurrentHashMap<String, Deferred<LinkPreviewMetadata?>>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // Redirects disabled: auto-follow could bounce a public URL to an internal
    // host, bypassing the SSRF guard applied to the initial URL.
    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .followRedirects(false)
        .followSslRedirects(false)
        .build()

    private var cacheDirectory: File? = null

    fun setCacheDirectory(dir: File) {
        cacheDirectory = dir.also { it.mkdirs() }
    }

    // ══════════════════════════════════════════════════════════════════
    // Public API
    // ══════════════════════════════════════════════════════════════════

    /**
     * Fetch OpenGraph metadata for a URL with multi-layer caching
     * and request coalescing.
     */
    suspend fun fetchMetadata(url: String): LinkPreviewMetadata? {
        // 1. Memory cache
        memoryCache.get(url)?.let { return it }

        // 2. Negative cache
        if (failedURLs.contains(url)) return null

        // 3. Disk cache
        loadFromDisk(url)?.let { metadata ->
            memoryCache.put(url, metadata)
            return metadata
        }

        // 4. Coalesce concurrent requests
        inFlightRequests[url]?.let { return it.await() }

        // 5. Fetch from network
        val deferred = scope.async {
            try {
                val metadata = fetchOGMetadata(url)
                if (metadata != null) {
                    memoryCache.put(url, metadata)
                    saveToDisk(metadata, url)
                } else {
                    markURLFailed(url)
                }
                metadata
            } catch (e: Exception) {
                Log.w(TAG, "OG fetch failed for $url: ${e.message}")
                markURLFailed(url)
                null
            } finally {
                inFlightRequests.remove(url)
            }
        }

        inFlightRequests[url] = deferred
        return deferred.await()
    }

    // ══════════════════════════════════════════════════════════════════
    // OG Fetching
    // ══════════════════════════════════════════════════════════════════

    private fun fetchOGMetadata(url: String): LinkPreviewMetadata? {
        // SSRF guard: the app runs a local relay/Blossom/bridge on localhost.
        if (!com.nostrvault.util.UrlSafety.isSafeRemoteUrl(url)) return null

        val request = Request.Builder()
            .url(url)
            .addHeader("User-Agent", BROWSER_USER_AGENT)
            .get()
            .build()

        val response = httpClient.newCall(request).execute()
        if (!response.isSuccessful) return null

        val contentType = response.header("Content-Type") ?: ""
        if (!contentType.contains("text/html", ignoreCase = true)) return null

        // Read first 50KB
        val body = response.body ?: return null
        val source = body.source()
        val html = source.readUtf8(minOf(body.contentLength().coerceAtLeast(0), MAX_HTML_BYTES.toLong()))
        body.close()

        return parseOGTags(html, url)
    }

    private fun parseOGTags(html: String, sourceURL: String): LinkPreviewMetadata? {
        val ogTags = mutableMapOf<String, String>()

        // Pattern 1: property="og:xxx" content="yyy"
        for (match in OG_PROPERTY_REGEX.findAll(html)) {
            ogTags[match.groupValues[1]] = match.groupValues[2]
        }

        // Pattern 2: content="yyy" property="og:xxx"
        for (match in OG_CONTENT_FIRST_REGEX.findAll(html)) {
            val property = match.groupValues[2]
            if (!ogTags.containsKey(property)) {
                ogTags[property] = match.groupValues[1]
            }
        }

        // Fallback to <title>
        val title = ogTags["title"] ?: run {
            TITLE_REGEX.find(html)?.groupValues?.get(1)?.trim()
        }

        if (title == null && ogTags.isEmpty()) return null

        // Resolve relative image URLs
        val imageURL = ogTags["image"]?.let { img ->
            if (img.startsWith("http")) img
            else try {
                val base = java.net.URI(sourceURL)
                base.resolve(img).toString()
            } catch (e: Exception) { img }
        // Guard the image URL too — it is later handed to Coil to load.
        }?.takeIf { com.nostrvault.util.UrlSafety.isSafeRemoteUrl(it) }

        return LinkPreviewMetadata(
            url = sourceURL,
            title = title ?: ogTags["title"],
            description = ogTags["description"],
            imageURL = imageURL,
            siteName = ogTags["site_name"],
        )
    }

    // ══════════════════════════════════════════════════════════════════
    // Disk cache
    // ══════════════════════════════════════════════════════════════════

    private fun cacheFilePath(url: String): File? {
        val dir = cacheDirectory ?: return null
        val hash = MessageDigest.getInstance("SHA-256")
            .digest(url.toByteArray())
            .joinToString("") { "%02x".format(it) }
        return File(dir, hash)
    }

    private fun loadFromDisk(url: String): LinkPreviewMetadata? {
        val file = cacheFilePath(url) ?: return null
        if (!file.exists()) return null

        // Check expiration
        val ageMs = System.currentTimeMillis() - file.lastModified()
        if (ageMs > DISK_CACHE_EXPIRY_DAYS * 24 * 60 * 60 * 1000L) {
            file.delete()
            return null
        }

        return try {
            json.decodeFromString<LinkPreviewMetadata>(file.readText())
        } catch (e: Exception) {
            file.delete()
            null
        }
    }

    private fun saveToDisk(metadata: LinkPreviewMetadata, url: String) {
        val file = cacheFilePath(url) ?: return
        try {
            file.writeText(json.encodeToString(LinkPreviewMetadata.serializer(), metadata))
        } catch (e: Exception) {
            Log.w(TAG, "Disk cache write failed: ${e.message}")
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Negative cache
    // ══════════════════════════════════════════════════════════════════

    private fun markURLFailed(url: String) {
        failedURLs.add(url)
    }

    fun isURLFailed(url: String): Boolean = failedURLs.contains(url)

    /**
     * Clear all caches.
     */
    fun clearCaches() {
        memoryCache.evictAll()
        failedURLs.clear()
        cacheDirectory?.listFiles()?.forEach { it.delete() }
    }
}

// ── Data model ────────────────────────────────────────────────────

@Serializable
data class LinkPreviewMetadata(
    val url: String,
    val title: String?,
    val description: String?,
    val imageURL: String?,
    val siteName: String?,
)
