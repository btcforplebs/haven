package com.nostrvault.service

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Saves media (images/videos) to the device gallery via MediaStore.
 */
@Singleton
class MediaSaveService @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    companion object {
        private const val TAG = "MediaSaveService"
    }

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    /**
     * Save a local file to the device gallery.
     */
    suspend fun saveToGallery(file: File, mimeType: String?): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val bytes = file.readBytes()
            saveBytes(bytes, file.name, mimeType ?: guessMimeType(file.name))
        } catch (e: Exception) {
            Log.e(TAG, "Save file to gallery failed", e)
            Result.failure(e)
        }
    }

    /**
     * Download from a URL and save to the device gallery.
     */
    suspend fun saveToGallery(url: String, mimeType: String?): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val request = Request.Builder().url(url).get().build()
            val response = httpClient.newCall(request).execute()
            if (!response.isSuccessful) {
                return@withContext Result.failure(Exception("Download failed: ${response.code}"))
            }
            val bytes = response.body?.bytes()
                ?: return@withContext Result.failure(Exception("Empty response"))
            val contentType = mimeType ?: response.header("Content-Type") ?: "image/jpeg"
            val filename = url.substringAfterLast('/').take(12)
            saveBytes(bytes, filename, contentType)
        } catch (e: Exception) {
            Log.e(TAG, "Save URL to gallery failed", e)
            Result.failure(e)
        }
    }

    private fun saveBytes(bytes: ByteArray, filename: String, mimeType: String): Result<Unit> {
        val isVideo = mimeType.startsWith("video")
        val collection = if (isVideo) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            } else {
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            }
        } else {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            } else {
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            }
        }

        val extension = mimeTypeToExtension(mimeType)
        val displayName = "NostrVault_${System.currentTimeMillis()}.$extension"

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val subdir = if (isVideo) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES
                put(MediaStore.MediaColumns.RELATIVE_PATH, "$subdir/NostrVault")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        }

        val resolver = context.contentResolver
        val uri = resolver.insert(collection, values)
            ?: return Result.failure(Exception("Failed to create MediaStore entry"))

        return try {
            resolver.openOutputStream(uri)?.use { it.write(bytes) }
                ?: return Result.failure(Exception("Failed to open output stream"))

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            }
            Result.success(Unit)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            Result.failure(e)
        }
    }

    private fun guessMimeType(filename: String): String {
        val ext = filename.substringAfterLast('.', "").lowercase()
        return when (ext) {
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "gif" -> "image/gif"
            "webp" -> "image/webp"
            "mp4" -> "video/mp4"
            "mov" -> "video/quicktime"
            "webm" -> "video/webm"
            else -> "image/jpeg"
        }
    }

    private fun mimeTypeToExtension(mimeType: String): String {
        return when (mimeType.lowercase()) {
            "image/jpeg" -> "jpg"
            "image/png" -> "png"
            "image/gif" -> "gif"
            "image/webp" -> "webp"
            "video/mp4" -> "mp4"
            "video/quicktime" -> "mov"
            "video/webm" -> "webm"
            else -> "jpg"
        }
    }
}
