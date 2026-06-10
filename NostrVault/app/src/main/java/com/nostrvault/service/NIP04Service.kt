package com.nostrvault.service

import android.util.Log
import com.nostrvault.relay.HavenBridge

/**
 * Port of NIP04Service.swift -- legacy AES-256-CBC encryption.
 * All crypto is delegated to the Go FFI bridge.
 */
object NIP04Service {

    private const val TAG = "NIP04Service"

    /**
     * Encrypt plaintext using NIP-04 (AES-256-CBC with shared secret).
     * Returns the encrypted string, or null on failure.
     */
    fun encrypt(plaintext: String, pubkey: String, privkey: String): String? {
        if (!HavenBridge.isLoaded) {
            Log.e(TAG, "Cannot encrypt: libhaven.so not loaded")
            return null
        }
        return try {
            HavenBridge.encryptNIP04(plaintext, pubkey, privkey)
        } catch (e: Exception) {
            Log.e(TAG, "NIP-04 encrypt failed: ${e.message}")
            null
        }
    }

    /**
     * Decrypt ciphertext using NIP-04 (AES-256-CBC with shared secret).
     * Returns the decrypted plaintext, or null on failure.
     */
    fun decrypt(ciphertext: String, pubkey: String, privkey: String): String? {
        if (!HavenBridge.isLoaded) {
            Log.e(TAG, "Cannot decrypt: libhaven.so not loaded")
            return null
        }
        return try {
            HavenBridge.decryptNIP04(ciphertext, pubkey, privkey)
        } catch (e: Exception) {
            Log.e(TAG, "NIP-04 decrypt failed: ${e.message}")
            null
        }
    }
}
