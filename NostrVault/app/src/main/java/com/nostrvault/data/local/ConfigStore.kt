package com.nostrvault.data.local

import android.content.Context
import com.nostrvault.relay.HavenConfig
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Port of ConfigService.swift persistence layer.
 * Uses JSON file persistence (matching iOS approach) with StateFlow
 * for reactive config updates.
 *
 * Complex config properties (relay URLs, account management, etc.) are
 * stored in HavenConfig and serialized to config.json.
 */
@Singleton
class ConfigStore @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true }
    private val configFile get() = File(context.filesDir, "nostrvault_config.json")

    private val _config = MutableStateFlow(HavenConfig())
    val config: StateFlow<HavenConfig> = _config.asStateFlow()

    private val _activeAccountHexPubkey = MutableStateFlow("")
    val activeAccountHexPubkey: StateFlow<String> = _activeAccountHexPubkey.asStateFlow()

    private val _isSwitchingAccount = MutableStateFlow(false)
    val isSwitchingAccount: StateFlow<Boolean> = _isSwitchingAccount.asStateFlow()

    /** Load config from disk or create defaults. */
    fun reload() {
        _config.value = try {
            if (configFile.exists()) {
                json.decodeFromString(configFile.readText())
            } else {
                HavenConfig()
            }
        } catch (_: Exception) {
            HavenConfig()
        }
    }

    /** Persist current config to disk. */
    suspend fun save() = withContext(Dispatchers.IO) {
        try {
            configFile.writeText(json.encodeToString(_config.value))
        } catch (_: Exception) { }
    }

    /** Update config and auto-save (suspend). */
    suspend fun updateAsync(transform: (HavenConfig) -> HavenConfig) {
        _config.value = transform(_config.value)
        save()
    }

    /** Update config synchronously (saves in background). */
    fun update(transform: (HavenConfig) -> HavenConfig) {
        _config.value = transform(_config.value)
        kotlinx.coroutines.CoroutineScope(Dispatchers.IO).launch { save() }
    }

    /** Set active account pubkey. */
    fun setActiveAccount(hexPubkey: String) {
        _activeAccountHexPubkey.value = hexPubkey
    }

    fun setSwitchingAccount(switching: Boolean) {
        _isSwitchingAccount.value = switching
    }

    /** Factory reset -- delete config and all data. */
    suspend fun resetApp() = withContext(Dispatchers.IO) {
        configFile.delete()
        _config.value = HavenConfig()
        _activeAccountHexPubkey.value = ""
    }
}
