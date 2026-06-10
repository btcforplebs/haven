package com.nostrvault.service

import android.util.Log
import com.nostrvault.relay.HavenBridge
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Port of NIP46Service / cshared.go NIP-46 bridge -- remote signer protocol.
 * All operations delegate to the Go FFI bridge which manages the bunker
 * client lifecycle, WebSocket subscriptions, and RPC timeouts.
 */
object NIP46Service {

    private const val TAG = "NIP46Service"

    /**
     * Connect to a NIP-46 bunker.
     * @param clientSecretKey Hex secret key for the NIP-46 client session.
     * @param bunkerUrl Full bunker:// URL with relay, pubkey, and secret.
     * @return The signer's public key hex on success, null on failure.
     */
    suspend fun connect(clientSecretKey: String, bunkerUrl: String): String? =
        withContext(Dispatchers.IO) {
            try {
                HavenBridge.nip46Connect(clientSecretKey, bunkerUrl)
            } catch (e: Exception) {
                Log.e(TAG, "NIP-46 connect failed: ${e.message}")
                null
            }
        }

    /** Disconnect from the NIP-46 bunker. */
    fun disconnect() {
        try {
            HavenBridge.nip46Disconnect()
        } catch (e: Exception) {
            Log.e(TAG, "NIP-46 disconnect failed: ${e.message}")
        }
    }

    /**
     * Sign an event via the remote signer.
     * @return Signed event JSON string, or null on failure.
     */
    suspend fun signEvent(eventJson: String): String? =
        withContext(Dispatchers.IO) {
            try {
                HavenBridge.nip46SignEvent(eventJson)
            } catch (e: Exception) {
                Log.e(TAG, "NIP-46 sign failed: ${e.message}")
                null
            }
        }

    /** Get the signer's public key. */
    suspend fun getPublicKey(): String? =
        withContext(Dispatchers.IO) {
            try {
                HavenBridge.nip46GetPublicKey()
            } catch (e: Exception) {
                Log.e(TAG, "NIP-46 getPublicKey failed: ${e.message}")
                null
            }
        }

    /** Encrypt via NIP-44 through the remote signer. */
    suspend fun nip44Encrypt(targetPubkey: String, plaintext: String): String? =
        withContext(Dispatchers.IO) {
            try {
                HavenBridge.nip46NIP44Encrypt(targetPubkey, plaintext)
            } catch (e: Exception) {
                Log.e(TAG, "NIP-46 NIP44 encrypt failed: ${e.message}")
                null
            }
        }

    /** Decrypt via NIP-44 through the remote signer. */
    suspend fun nip44Decrypt(targetPubkey: String, ciphertext: String): String? =
        withContext(Dispatchers.IO) {
            try {
                HavenBridge.nip46NIP44Decrypt(targetPubkey, ciphertext)
            } catch (e: Exception) {
                Log.e(TAG, "NIP-46 NIP44 decrypt failed: ${e.message}")
                null
            }
        }

    /** Encrypt via NIP-04 through the remote signer. */
    suspend fun nip04Encrypt(targetPubkey: String, plaintext: String): String? =
        withContext(Dispatchers.IO) {
            try {
                HavenBridge.nip46NIP04Encrypt(targetPubkey, plaintext)
            } catch (e: Exception) {
                Log.e(TAG, "NIP-46 NIP04 encrypt failed: ${e.message}")
                null
            }
        }

    /** Decrypt via NIP-04 through the remote signer. */
    suspend fun nip04Decrypt(targetPubkey: String, ciphertext: String): String? =
        withContext(Dispatchers.IO) {
            try {
                HavenBridge.nip46NIP04Decrypt(targetPubkey, ciphertext)
            } catch (e: Exception) {
                Log.e(TAG, "NIP-46 NIP04 decrypt failed: ${e.message}")
                null
            }
        }

    /** Ping the remote signer. Returns true on success. */
    suspend fun ping(): Boolean =
        withContext(Dispatchers.IO) {
            try {
                HavenBridge.nip46Ping() == 0
            } catch (e: Exception) {
                Log.e(TAG, "NIP-46 ping failed: ${e.message}")
                false
            }
        }

    /** Get pending auth URL (consumed on read). */
    fun getPendingAuthUrl(): String? =
        try {
            HavenBridge.nip46GetPendingAuthUrl()
        } catch (e: Exception) {
            null
        }
}
