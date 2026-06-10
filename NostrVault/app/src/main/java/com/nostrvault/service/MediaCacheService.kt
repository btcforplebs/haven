package com.nostrvault.service

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.util.Log
import android.util.LruCache
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Comprehensive media caching system.
 * Handles local file resolution, thumbnail generation, download coalescing,
 * and 404 tracking.
 *
 * Port of MediaCacheService.swift.
 */
@Singleton
class MediaCacheService @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    companion object {
        private const val TAG = "MediaCacheService"
        private const val IMAGE_CACHE_MAX_SIZE = 60 * 1024 * 1024 // 60 MB
        private const val THUMBNAIL_MAX_ENTRIES = 200
        private const val MAX_CONCURRENT_DOWNLOADS = 4
        private const val MAX_CONCURRENT_THUMBNAILS = 2
        private const val MIN_CACHE_SIZE = 100L // bytes
        private const val TTL_DAYS = 30
    }

    // ── Caches ────────────────────────────────────────────────────────

    private val imageCache = object : LruCache<String, ByteArray>(IMAGE_CACHE_MAX_SIZE) {
        override fun sizeOf(key: String, value: ByteArray): Int = value.size
    }

    private val thumbnailCache = LruCache<String, Bitmap>(THUMBNAIL_MAX_ENTRIES)

    // ── Memory pressure eviction ─────────────────────────────────────

    /** Clear all in-memory caches (called on critical memory pressure). */
    fun evictMemoryCaches() {
        imageCache.evictAll()
        thumbnailCache.evictAll()
        Log.i(TAG, "Evicted all memory caches")
    }

    /** Trim in-memory caches to half capacity (called on moderate pressure). */
    fun trimMemoryCaches() {
        imageCache.trimToSize(IMAGE_CACHE_MAX_SIZE / 2)
        thumbnailCache.trimToSize(THUMBNAIL_MAX_ENTRIES / 2)
        Log.i(TAG, "Trimmed memory caches to 50%")
    }

    // ── Directories ───────────────────────────────────────────────────

    val cacheDirectory: File by lazy {
        File(context.cacheDir, "media_cache").also { it.mkdirs() }
    }

    val thumbnailDirectory: File by lazy {
        File(context.cacheDir, "thumbnails").also { it.mkdirs() }
    }

    private var blossomDirectory: File? = null
    private var localHost: String? = null

    // ── Download coalescing ───────────────────────────────────────────

    private val inFlightDownloads = ConcurrentHashMap<String, Deferred<ByteArray?>>()
    private val inFlightThumbnails = ConcurrentHashMap<String, Deferred<Bitmap?>>()
    private val downloadSemaphore = Semaphore(MAX_CONCURRENT_DOWNLOADS)
    private val thumbnailSemaphore = Semaphore(MAX_CONCURRENT_THUMBNAILS)

    // ── 404 Tracking ──────────────────────────────────────────────────

    private val notFoundURLs = ConcurrentHashMap.newKeySet<String>()
    private val prefs by lazy {
        context.getSharedPreferences("media_cache_404", Context.MODE_PRIVATE)
    }

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    init {
        // Load persisted 404s
        val saved = prefs.getStringSet("not_found_urls", emptySet()) ?: emptySet()
        notFoundURLs.addAll(saved)
    }

    // ══════════════════════════════════════════════════════════════════
    // Configuration
    // ══════════════════════════════════════════════════════════════════

    fun updateLocalHost(host: String?) {
        localHost = host
    }

    fun updateBlossomDirectory(dir: File?) {
        blossomDirectory = dir
    }

    // ══════════════════════════════════════════════════════════════════
    // In-memory image cache
    // ══════════════════════════════════════════════════════════════════

    fun cachedImage(url: String): ByteArray? = imageCache.get(hashUrl(url))

    fun cacheImage(data: ByteArray, url: String) {
        imageCache.put(hashUrl(url), data)
    }

    // ══════════════════════════════════════════════════════════════════
    // 404 Tracking
    // ══════════════════════════════════════════════════════════════════

    fun isKnown404(url: String): Boolean = notFoundURLs.contains(url)

    fun markNotFound(url: String) {
        notFoundURLs.add(url)
        prefs.edit().putStringSet("not_found_urls", notFoundURLs.toSet()).apply()
    }

    fun unmarkNotFound(url: String) {
        notFoundURLs.remove(url)
        prefs.edit().putStringSet("not_found_urls", notFoundURLs.toSet()).apply()
    }

    // ══════════════════════════════════════════════════════════════════
    // File path resolution
    // ══════════════════════════════════════════════════════════════════

    fun cachePath(url: String): File = File(cacheDirectory, hashUrl(url))

    fun isCached(url: String): Boolean = cachePath(url).exists()

    fun saveToCache(url: String, data: ByteArray) {
        if (data.size < MIN_CACHE_SIZE) return
        val file = cachePath(url)
        file.writeBytes(data)
    }

    fun loadFromCache(url: String): ByteArray? {
        val file = cachePath(url)
        return if (file.exists()) file.readBytes() else null
    }

    /**
     * Get local file URL for a remote URL.
     * Returns null for localhost URLs (to preserve MIME types).
     */
    fun localFileUrl(url: String): File? {
        if (isLocalUrl(url)) return null

        // Try Blossom directory first
        blossomDirectory?.let { bDir ->
            val hash = extractBlossomHash(url)
            if (hash != null) {
                val blossomFile = blossomFile(forHash = hash)
                if (blossomFile != null) return blossomFile
            }
        }

        // Try general cache
        val cached = cachePath(url)
        return if (cached.exists()) cached else null
    }

    // ══════════════════════════════════════════════════════════════════
    // Blossom file resolution
    // ══════════════════════════════════════════════════════════════════

    fun blossomFile(named: String): File? {
        val dir = blossomDirectory ?: return null
        val file = File(dir, named)
        return if (file.exists()) file else null
    }

    fun blossomFile(forHash: String, extensionHint: String? = null): File? {
        val dir = blossomDirectory ?: return null
        if (forHash.length != 64) return null

        // Try exact hash match
        val exact = File(dir, forHash)
        if (exact.exists()) return exact

        // Try with common extensions
        val extensions = listOf(
            extensionHint, "jpg", "jpeg", "png", "gif", "webp",
            "mp4", "mov", "webm", "mp3", "wav",
        ).filterNotNull().distinct()

        for (ext in extensions) {
            val withExt = File(dir, "$forHash.$ext")
            if (withExt.exists()) return withExt
        }

        return null
    }

    fun isInLocalBlossom(hash: String): Boolean {
        if (hash.length != 64) return false
        return blossomFile(forHash = hash) != null
    }

    // ══════════════════════════════════════════════════════════════════
    // Download & fetch
    // ══════════════════════════════════════════════════════════════════

    /**
     * Download media with request coalescing.
     */
    suspend fun fetchData(url: String): ByteArray? {
        // Check memory cache
        cachedImage(url)?.let { return it }

        // Check disk cache
        loadFromCache(url)?.let { data ->
            cacheImage(data, url)
            return data
        }

        // Check if already downloading
        inFlightDownloads[url]?.let { return it.await() }

        // Start new download
        val deferred = scope.async {
            downloadSemaphore.acquire()
            try {
                val request = Request.Builder().url(url).get().build()
                val response = httpClient.newCall(request).execute()

                if (!response.isSuccessful) {
                    if (response.code == 404) markNotFound(url)
                    return@async null
                }

                val data = response.body?.bytes() ?: return@async null
                saveToCache(url, data)
                cacheImage(data, url)
                data
            } catch (e: Exception) {
                Log.w(TAG, "Download failed for $url: ${e.message}")
                null
            } finally {
                downloadSemaphore.release()
                inFlightDownloads.remove(url)
            }
        }

        inFlightDownloads[url] = deferred
        return deferred.await()
    }

    // ══════════════════════════════════════════════════════════════════
    // Video thumbnails
    // ══════════════════════════════════════════════════════════════════

    fun cachedThumbnail(url: String): Bitmap? {
        // Check memory
        thumbnailCache.get(hashUrl(url))?.let { return it }

        // Check disk
        val diskFile = File(thumbnailDirectory, "${hashUrl(url)}.jpg")
        if (diskFile.exists()) {
            val bitmap = android.graphics.BitmapFactory.decodeFile(diskFile.absolutePath)
            if (bitmap != null) {
                thumbnailCache.put(hashUrl(url), bitmap)
                return bitmap
            }
        }

        return null
    }

    /**
     * Generate a video thumbnail with coalescing.
     */
    suspend fun generateThumbnail(url: String): Bitmap? {
        // Check existing
        cachedThumbnail(url)?.let { return it }

        // Check if already generating
        inFlightThumbnails[url]?.let { return it.await() }

        val deferred = scope.async {
            thumbnailSemaphore.acquire()
            try {
                // Ensure file is local
                val localFile = localFileUrl(url)
                    ?: run {
                        fetchData(url)
                        cachePath(url).takeIf { it.exists() }
                    }
                    ?: return@async null

                renderThumbnail(localFile)?.also { bitmap ->
                    // Save to disk
                    val diskFile = File(thumbnailDirectory, "${hashUrl(url)}.jpg")
                    FileOutputStream(diskFile).use { out ->
                        bitmap.compress(Bitmap.CompressFormat.JPEG, 75, out)
                    }
                    thumbnailCache.put(hashUrl(url), bitmap)
                }
            } catch (e: Exception) {
                Log.w(TAG, "Thumbnail generation failed for $url: ${e.message}")
                null
            } finally {
                thumbnailSemaphore.release()
                inFlightThumbnails.remove(url)
            }
        }

        inFlightThumbnails[url] = deferred
        return deferred.await()
    }

    private fun renderThumbnail(file: File): Bitmap? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.absolutePath)
            // Try multiple time points
            val timePoints = listOf(0L, 1_000_000L, 3_000_000L) // 0s, 1s, 3s in microseconds
            for (timeUs in timePoints) {
                val frame = retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                if (frame != null) return frame
            }
            null
        } catch (e: Exception) {
            Log.w(TAG, "MediaMetadataRetriever failed: ${e.message}")
            null
        } finally {
            retriever.release()
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Source detection
    // ══════════════════════════════════════════════════════════════════

    enum class MediaSource { BLOSSOM, CACHED, REMOTE }

    fun getSource(url: String): MediaSource {
        val hash = extractBlossomHash(url)
        if (hash != null && isInLocalBlossom(hash)) return MediaSource.BLOSSOM
        if (isCached(url)) return MediaSource.CACHED
        return MediaSource.REMOTE
    }

    // ══════════════════════════════════════════════════════════════════
    // Cleanup
    // ══════════════════════════════════════════════════════════════════

    fun clearCache() {
        cacheDirectory.listFiles()?.forEach { it.delete() }
        imageCache.evictAll()
    }

    fun evictExpiredFiles(ttlDays: Int = TTL_DAYS) {
        scope.launch {
            val cutoff = System.currentTimeMillis() - (ttlDays * 24 * 60 * 60 * 1000L)
            cacheDirectory.listFiles()?.forEach { file ->
                if (file.lastModified() < cutoff) file.delete()
            }
            thumbnailDirectory.listFiles()?.forEach { file ->
                if (file.lastModified() < cutoff) file.delete()
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Utilities
    // ══════════════════════════════════════════════════════════════════

    fun isLocalUrl(url: String): Boolean {
        val lower = url.lowercase()
        return lower.contains("localhost") || lower.contains("127.0.0.1") ||
            (localHost != null && lower.contains(localHost!!.lowercase()))
    }

    fun hashUrl(url: String): String {
        // Check if URL contains a 64-char hex hash (Blossom)
        val hash = extractBlossomHash(url)
        if (hash != null) return hash

        // SHA-256 hash the URL
        val digest = MessageDigest.getInstance("SHA-256")
        return digest.digest(url.toByteArray()).joinToString("") { "%02x".format(it) }
    }

    private fun extractBlossomHash(url: String): String? {
        val path = url.substringAfterLast('/')
            .substringBefore('?')
            .substringBefore('.')
        return if (path.length == 64 && path.all { it in "0123456789abcdef" }) path else null
    }
}
