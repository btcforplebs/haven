package com.nostrvault.service

import android.util.Log
import com.nostrvault.relay.HavenBridge

/**
 * Port of NIP44Service.swift -- modern ChaCha20-Poly1305 encryption.
 * All crypto is delegated to the Go FFI bridge.
 */
object NIP44Service {

    private const val TAG = "NIP44Service"

    /**
     * Encrypt plaintext using NIP-44 (ChaCha20-Poly1305 with conversation key).
     * Returns the encrypted string, or null on failure.
     */
    fun encrypt(plaintext: String, pubkey: String, privkey: String): String? {
        if (!HavenBridge.isLoaded) {
            Log.e(TAG, "Cannot encrypt: libhaven.so not loaded")
            return null
        }
        return try {
            HavenBridge.encryptNIP44(plaintext, pubkey, privkey)
        } catch (e: Exception) {
            Log.e(TAG, "NIP-44 encrypt failed: ${e.message}")
            null
        }
    }

    /**
     * Decrypt ciphertext using NIP-44 (ChaCha20-Poly1305 with conversation key).
     * Returns the decrypted plaintext, or null on failure.
     */
    fun decrypt(ciphertext: String, pubkey: String, privkey: String): String? {
        if (!HavenBridge.isLoaded) {
            Log.e(TAG, "Cannot decrypt: libhaven.so not loaded")
            return null
        }
        return try {
            HavenBridge.decryptNIP44(ciphertext, pubkey, privkey)
        } catch (e: Exception) {
            Log.e(TAG, "NIP-44 decrypt failed: ${e.message}")
            null
        }
    }
}
