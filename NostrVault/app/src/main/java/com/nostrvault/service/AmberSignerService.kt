package com.nostrvault.service

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenBridge
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

/**
 * NIP-55 Android Signer Application protocol implementation.
 * Communicates with Amber (or any NIP-55 signer) via intents and content providers.
 *
 * - Intent-based: launches signer Activity, user approves, result returns via ActivityResult
 * - ContentProvider-based: silent background signing after user checks "remember my choice"
 */
@Singleton
class AmberSignerService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val configStore: ConfigStore,
) {
    companion object {
        private const val TAG = "AmberSignerService"
        private const val DEFAULT_PACKAGE = "com.greenart7c3.nostrsigner"
        private const val INTENT_TIMEOUT_MS = 120_000L // 2 minutes for user interaction
    }

    /**
     * Serializes all signer round-trips. Amber funnels signing through a single
     * activity / content-provider and silently drops requests that arrive while
     * another is in flight. Concurrent callers (e.g. mirroring many blobs at
     * once) must queue, or signatures are lost ("Amber ignored it, moved too fast").
     */
    private val signerLock = Mutex()

    /** Cached after first successful get_public_key call. */
    var cachedPubkey: String? = null
        private set

    /** Amber's package name, updated from the get_public_key response. */
    var signerPackage: String = DEFAULT_PACKAGE
        private set

    init {
        restoreCachedPubkey()
    }

    /** Restore the cached pubkey from config so signing works after app restart. */
    private fun restoreCachedPubkey() {
        if (cachedPubkey != null) return
        val config = configStore.config.value
        if (config.signingMode != "amber") return

        val npub = config.ownerNpub
        val hex = when {
            npub.isEmpty() -> null
            npub.startsWith("npub1") -> HavenBridge.decodeNpub(npub)
            npub.length == 64 && npub.all { it in '0'..'9' || it in 'a'..'f' } -> npub
            else -> null
        }
        if (hex != null) {
            cachedPubkey = hex
            Log.d(TAG, "Restored cachedPubkey from config: ${hex.take(12)}...")
        }
        config.amberSignerPackage.takeIf { it.isNotEmpty() }?.let { signerPackage = it }
    }

    // ══════════════════════════════════════════════════════════════════
    // Detection
    // ══════════════════════════════════════════════════════════════════

    /** Check whether Amber (or any NIP-55 signer) is installed. */
    fun isAmberInstalled(): Boolean {
        return try {
            context.packageManager.getPackageInfo(DEFAULT_PACKAGE, 0)
            true
        } catch (_: PackageManager.NameNotFoundException) {
            // Also try a generic query for nostrsigner: scheme
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse("nostrsigner:"))
            val resolved = context.packageManager.queryIntentActivities(intent, 0)
            resolved.isNotEmpty()
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Public key
    // ══════════════════════════════════════════════════════════════════

    /** Get the user's public key from the signer. First call also caches the package name. */
    suspend fun getPublicKey(): String? {
        // Try content provider first
        tryContentProvider("GET_PUBLIC_KEY")?.let { result ->
            cachedPubkey = result
            return result
        }

        // Intent fallback
        val requestId = UUID.randomUUID().toString()
        val intent = buildIntent("get_public_key", requestId).apply {
            // Request broad permissions for background signing
            val permsJson = """[{"type":"sign_event"},{"type":"nip04_encrypt"},{"type":"nip04_decrypt"},{"type":"nip44_encrypt"},{"type":"nip44_decrypt"}]"""
            putExtra("permissions", permsJson)
        }

        val result = withTimeoutOrNull(INTENT_TIMEOUT_MS) {
            AmberResultBridge.launchAndAwait(intent, requestId)
        } ?: return null

        if (!result.rejected && result.resultCode == android.app.Activity.RESULT_OK) {
            cachedPubkey = result.pubkey
            result.packageName?.let { signerPackage = it }
            Log.i(TAG, "Got pubkey from Amber: ${result.pubkey?.take(12)}...")
            return result.pubkey
        }

        Log.w(TAG, "Amber get_public_key rejected")
        return null
    }

    // ══════════════════════════════════════════════════════════════════
    // Event signing
    // ══════════════════════════════════════════════════════════════════

    /** Sign an event. Returns the full signed event JSON, or null on failure. */
    suspend fun signEvent(unsignedEventJson: String): String? {
        if (cachedPubkey == null) restoreCachedPubkey()
        val currentUser = cachedPubkey
        if (currentUser == null) {
            Log.e(TAG, "signEvent: cachedPubkey is null, cannot sign (ownerNpub=${configStore.config.value.ownerNpub.take(12)}, bridgeLoaded=${HavenBridge.isLoaded})")
            return null
        }

        // Serialize: concurrent signs race Amber's single activity and get dropped.
        return signerLock.withLock {
            // Try content provider first (silent background signing)
            tryContentProviderSign(unsignedEventJson, currentUser)?.let { return@withLock it }

            // Intent fallback (launches Amber for approval)
            val requestId = UUID.randomUUID().toString()
            val intent = buildIntent("sign_event", requestId).apply {
                data = Uri.parse("nostrsigner:$unsignedEventJson")
                putExtra("current_user", currentUser)
            }

            val result = withTimeoutOrNull(INTENT_TIMEOUT_MS) {
                AmberResultBridge.launchAndAwait(intent, requestId)
            }

            when {
                result == null -> {
                    Log.w(TAG, "Amber sign_event timed out")
                    null
                }
                !result.rejected && result.resultCode == android.app.Activity.RESULT_OK -> result.event
                else -> {
                    Log.w(TAG, "Amber sign_event rejected")
                    null
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Encryption / decryption
    // ══════════════════════════════════════════════════════════════════

    suspend fun nip04Encrypt(plaintext: String, recipientPubkey: String): String? =
        cryptoOp("nip04_encrypt", "NIP04_ENCRYPT", plaintext, recipientPubkey)

    suspend fun nip04Decrypt(ciphertext: String, senderPubkey: String): String? =
        cryptoOp("nip04_decrypt", "NIP04_DECRYPT", ciphertext, senderPubkey)

    suspend fun nip44Encrypt(plaintext: String, recipientPubkey: String): String? =
        cryptoOp("nip44_encrypt", "NIP44_ENCRYPT", plaintext, recipientPubkey)

    suspend fun nip44Decrypt(ciphertext: String, senderPubkey: String): String? =
        cryptoOp("nip44_decrypt", "NIP44_DECRYPT", ciphertext, senderPubkey)

    // ══════════════════════════════════════════════════════════════════
    // Internal helpers
    // ══════════════════════════════════════════════════════════════════

    private suspend fun cryptoOp(
        intentType: String,
        contentProviderType: String,
        payload: String,
        pubkey: String,
    ): String? {
        val currentUser = cachedPubkey ?: return null

        // Try content provider first
        tryContentProvider(contentProviderType, payload, currentUser, pubkey)?.let { return it }

        // Intent fallback
        val requestId = UUID.randomUUID().toString()
        val intent = buildIntent(intentType, requestId).apply {
            data = Uri.parse("nostrsigner:$payload")
            putExtra("current_user", currentUser)
            putExtra("pubkey", pubkey)
        }

        val result = withTimeoutOrNull(INTENT_TIMEOUT_MS) {
            AmberResultBridge.launchAndAwait(intent, requestId)
        } ?: return null

        return if (!result.rejected && result.resultCode == android.app.Activity.RESULT_OK) {
            result.pubkey // NIP-55 returns crypto results in the "result" extra
        } else null
    }

    private fun buildIntent(type: String, requestId: String): Intent {
        return Intent(Intent.ACTION_VIEW, Uri.parse("nostrsigner:")).apply {
            `package` = signerPackage
            putExtra("type", type)
            putExtra("id", requestId)
        }
    }

    /** Attempt content provider query for background operations. */
    private fun tryContentProvider(
        method: String,
        payload: String? = null,
        currentUser: String? = null,
        pubkey: String? = null,
    ): String? = try {
        val uri = Uri.parse("content://$signerPackage.$method")
        val selectionArgs = buildList {
            add(payload ?: "")
            add(pubkey ?: "")
            add(currentUser ?: cachedPubkey ?: "")
        }.toTypedArray()

        val cursor = context.contentResolver.query(uri, null, null, selectionArgs, null)
        cursor?.use {
            if (it.moveToFirst()) {
                val idx = it.getColumnIndex("result")
                if (idx >= 0) it.getString(idx) else null
            } else null
        }
    } catch (e: Exception) {
        Log.d(TAG, "ContentProvider $method not available: ${e.message}")
        null
    }

    /** Content provider specifically for sign_event (returns "event" column). */
    private fun tryContentProviderSign(eventJson: String, currentUser: String): String? = try {
        val uri = Uri.parse("content://$signerPackage.SIGN_EVENT")
        val selectionArgs = arrayOf(eventJson, "", currentUser)

        val cursor = context.contentResolver.query(uri, null, null, selectionArgs, null)
        cursor?.use {
            if (it.moveToFirst()) {
                // Check for rejection
                val rejectedIdx = it.getColumnIndex("rejected")
                if (rejectedIdx >= 0) return@use null

                val eventIdx = it.getColumnIndex("event")
                if (eventIdx >= 0) it.getString(eventIdx) else null
            } else null
        }
    } catch (e: Exception) {
        Log.d(TAG, "ContentProvider SIGN_EVENT not available: ${e.message}")
        null
    }
}
