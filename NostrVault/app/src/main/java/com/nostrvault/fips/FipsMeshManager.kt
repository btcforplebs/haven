package com.nostrvault.fips

import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Owns the mesh endpoint's lifetime and its network identity.
 *
 * The identity is the whole point of this class. [FipsBridge.start] takes an
 * nsec and the npub derived from it *is* the address other people dial, so a
 * key that is not persisted means a new address every launch and nobody can
 * reach you twice. It lives in [CredentialStore] (AndroidKeyStore-backed),
 * separate from the account keys — the mesh address should be rotatable
 * without touching the social identity.
 */
@Singleton
class FipsMeshManager @Inject constructor(
    private val credentialStore: CredentialStore,
    private val configStore: ConfigStore,
) {

    private val _status = MutableStateFlow(FipsStatus.stopped)
    val status: StateFlow<FipsStatus> = _status.asStateFlow()

    /** Last failure, for the UI. Cleared by a successful start. */
    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    /** False when this build ships no mesh library for the device's ABI. */
    val isAvailable: Boolean get() = FipsBridge.isAvailable

    /** Start on launch if the user left it on. */
    fun restoreIfEnabled(scope: CoroutineScope) {
        if (!configStore.config.value.fipsMeshEnabled) return
        scope.launch { start(persist = false) }
    }

    /**
     * Bind the endpoint, generating and persisting an identity the first time.
     *
     * [persist] is false when restoring a preference that is already stored —
     * writing it back on every launch would be a no-op with a disk write.
     */
    suspend fun start(persist: Boolean = true): Boolean = withContext(Dispatchers.IO) {
        if (!FipsBridge.isAvailable) {
            _lastError.value = "This build has no mesh library for your device."
            return@withContext false
        }

        val nsec = credentialStore.getMeshNsec() ?: FipsBridge.generateNsec()?.also {
            if (!credentialStore.storeMeshNsec(it)) {
                // Starting anyway would hand out an address that dies with the
                // process, which is worse than not starting: a peer would save
                // it and never reach us again.
                _lastError.value = "Could not save the mesh identity."
                return@withContext false
            }
        }
        if (nsec == null) {
            _lastError.value = "Could not create a mesh identity."
            return@withContext false
        }

        val rc = FipsBridge.start(nsec)
        if (rc != 0) {
            Log.w(TAG, "FipsBridgeStartWithIdentity failed: $rc")
            _lastError.value = "The mesh endpoint did not start (code $rc)."
            refresh()
            return@withContext false
        }

        _lastError.value = null
        if (persist) configStore.updateAsync { it.copy(fipsMeshEnabled = true) }
        refresh()
        true
    }

    suspend fun stop() = withContext(Dispatchers.IO) {
        FipsBridge.stop()
        configStore.updateAsync { it.copy(fipsMeshEnabled = false) }
        refresh()
    }

    /** Re-read the bridge. Polled: nothing ever calls back into the JVM. */
    suspend fun refresh() = withContext(Dispatchers.IO) {
        _status.value = FipsBridge.status()
    }

    private companion object {
        const val TAG = "FipsMeshManager"
    }
}
