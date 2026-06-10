package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.relay.HavenBridge

/**
 * Port of NIP49Service.swift -- password-protected key encryption.
 *
 * Encryption/decryption is handled by Go FFI bridge (scrypt + XChaCha20-Poly1305)
 * for full NIP-49 spec compliance.
 */
object NIP49Service {

    private const val TAG = "NIP49Service"

    sealed class NIP49Error(message: String) : Exception(message) {
        data object InvalidEncrypted : NIP49Error("Invalid encrypted key format")
        data object DecryptionFailed : NIP49Error("Failed to decrypt key with this password")
        data object InvalidPassword : NIP49Error("Password is required")
        data object EncodingFailed : NIP49Error("Failed to encode encrypted key")
        data object DecodingFailed : NIP49Error("Failed to decode encrypted key")
    }

    /**
     * Encrypt a private key (nsec hex) with a password to create ncryptsec format.
     * Uses Go FFI for NIP-49 spec-compliant scrypt + XChaCha20-Poly1305.
     */
    fun encrypt(nsecHex: String, password: String): String {
        if (password.isEmpty()) throw NIP49Error.InvalidPassword

        val result = HavenBridge.encryptNIP49(nsecHex, password)
            ?: throw NIP49Error.EncodingFailed

        return result
    }

    /**
     * Decrypt an ncryptsec key with a password to retrieve the private key hex.
     */
    fun decrypt(ncryptsec: String, password: String): String {
        if (password.isEmpty()) throw NIP49Error.InvalidPassword

        val result = HavenBridge.decryptNIP49(ncryptsec, password)
        if (result != null) return result

        Log.d(TAG, "Go FFI decrypt failed, ncryptsec may be invalid")
        throw NIP49Error.DecryptionFailed
    }

    /** Check if a string is in ncryptsec format. */
    fun isNcryptsec(value: String): Boolean =
        value.lowercase().startsWith("ncryptsec1")

    // ---- Keychain storage (delegates to CredentialStore) ----

    fun storePasswordInKeychain(password: String): Boolean =
        CredentialStore.storeOwnerPassword(password)

    fun getPasswordFromKeychain(): String? =
        CredentialStore.getOwnerPassword()

    fun deletePasswordFromKeychain(): Boolean =
        CredentialStore.deleteOwnerPassword()

    fun hasStoredPassword(): Boolean =
        CredentialStore.hasOwnerPassword()

    fun storePasswordInKeychain(password: String, forNpub: String): Boolean =
        CredentialStore.storePassword(password, forNpub)

    fun getPasswordFromKeychain(forNpub: String): String? =
        CredentialStore.getPassword(forNpub)

    fun deletePasswordFromKeychain(forNpub: String): Boolean =
        CredentialStore.deletePassword(forNpub)
}
