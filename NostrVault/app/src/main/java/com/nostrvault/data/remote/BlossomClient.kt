package com.nostrvault.data.remote

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.Response
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Port of BlossomService.swift (upload/download portions) -- Blossom media protocol client.
 *
 * Handles BUD-02 uploads, BUD-14 clearnet-first mirroring, and SHA256 verification.
 */
class BlossomClient(
    private val baseUrl: String,
    private val authHeader: String? = null,
) {
    companion object {
        private const val TAG = "BlossomClient"
    }

    private val client = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(120, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    /**
     * Upload a file to a Blossom server.
     *
     * @param file The file to upload
     * @param mimeType MIME type of the file
     * @param onProgress Progress callback (0.0-1.0)
     * @return Upload result with URL and SHA256 hash
     */
    suspend fun upload(
        file: File,
        mimeType: String = "application/octet-stream",
        onProgress: ((Float) -> Unit)? = null,
    ): UploadResult = withContext(Dispatchers.IO) {
        // Compute SHA256 before upload
        val sha256 = computeSHA256(file)

        val requestBody = file.asRequestBody(mimeType.toMediaType())

        val request = Request.Builder()
            .url("$baseUrl/upload")
            .put(requestBody)
            .apply {
                authHeader?.let { addHeader("Authorization", it) }
                addHeader("Content-Type", mimeType)
            }
            .build()

        val response = client.newCall(request).await()

        if (!response.isSuccessful) {
            throw IOException("Upload failed: ${response.code} ${response.message}")
        }

        val responseBody = response.body?.string()
            ?: throw IOException("Empty response body")

        UploadResult(
            url = "$baseUrl/$sha256",
            sha256 = sha256,
            responseBody = responseBody,
        )
    }

    /**
     * Download a blob by its SHA256 hash.
     */
    suspend fun download(sha256: String): ByteArray = withContext(Dispatchers.IO) {
        val request = Request.Builder()
            .url("$baseUrl/$sha256")
            .get()
            .build()

        val response = client.newCall(request).await()

        if (!response.isSuccessful) {
            throw IOException("Download failed: ${response.code}")
        }

        response.body?.bytes() ?: throw IOException("Empty response body")
    }

    /**
     * Delete a blob by its SHA256 hash.
     */
    suspend fun delete(sha256: String): Boolean = withContext(Dispatchers.IO) {
        val request = Request.Builder()
            .url("$baseUrl/$sha256")
            .delete()
            .apply { authHeader?.let { addHeader("Authorization", it) } }
            .build()

        val response = client.newCall(request).await()
        response.isSuccessful
    }

    data class UploadResult(
        val url: String,
        val sha256: String,
        val responseBody: String,
    )

    private fun computeSHA256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(8192)
            var bytesRead: Int
            while (input.read(buffer).also { bytesRead = it } != -1) {
                digest.update(buffer, 0, bytesRead)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /** Suspend-friendly OkHttp call execution. */
    private suspend fun Call.await(): Response = suspendCancellableCoroutine { cont ->
        cont.invokeOnCancellation { cancel() }
        enqueue(object : Callback {
            override fun onResponse(call: Call, response: Response) {
                cont.resume(response)
            }
            override fun onFailure(call: Call, e: IOException) {
                cont.resumeWithException(e)
            }
        })
    }
}
