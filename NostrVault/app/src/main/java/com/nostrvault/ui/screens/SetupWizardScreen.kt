package com.nostrvault.ui.screens

import android.content.Context
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.HavenConfig
import com.nostrvault.relay.RelayConfiguration
import com.nostrvault.service.AmberSignerService
import com.nostrvault.service.BlossomService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.URL
import javax.inject.Inject

/**
 * Setup wizard for first-run onboarding.
 * Full mode:   Welcome → Path → Account → Relays → Import → Media → Wallet → Complete
 * Browse mode: Welcome → Path → Account → Complete
 * Port of SetupWizardView.swift.
 */

// ── Wizard colors (from iOS WizardColors) ────────────────────────

private val WizardBgPrimary = Color(0xFF09090B)
private val WizardBgCard = Color(0xFF18181B)
private val WizardBgElevated = Color(0xFF27272A)
private val WizardBorderSubtle = Color.White.copy(alpha = 0.06f)
private val WizardBorderActive = Color(0xFFF59E0B).copy(alpha = 0.4f)
private val WizardAccent = Color(0xFFF59E0B)
private val WizardGradient = Brush.horizontalGradient(
    colors = listOf(Color(0xFFEA580C), Color(0xFFF59E0B)),
)

// ── Enums ────────────────────────────────────────────────────────

enum class WizardStep {
    WELCOME, CHOOSE_PATH, ACCOUNT, RELAYS, IMPORT_NOTES, MIRROR_MEDIA, WALLET, COMPLETE
}

enum class AccountMode { GENERATE, IMPORT, AMBER }
enum class SetupPath { NONE, FULL, BROWSE }

// ── ViewModel ────────────────────────────────────────────────────

@HiltViewModel
class SetupWizardViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val credentialStore: CredentialStore,
    private val amberSignerService: AmberSignerService,
    private val blossomService: BlossomService,
    @ApplicationContext private val appContext: Context,
) : ViewModel() {

    // Navigation
    private val _step = MutableStateFlow(WizardStep.WELCOME)
    val step = _step.asStateFlow()

    private val _setupPath = MutableStateFlow(SetupPath.NONE)
    val setupPath = _setupPath.asStateFlow()

    // Account
    private val _accountMode = MutableStateFlow(AccountMode.GENERATE)
    val accountMode = _accountMode.asStateFlow()

    private val _npubInput = MutableStateFlow("")
    val npubInput = _npubInput.asStateFlow()

    private val _nsecInput = MutableStateFlow("")
    val nsecInput = _nsecInput.asStateFlow()

    private val _passphrase = MutableStateFlow("")
    val passphrase = _passphrase.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading = _isLoading.asStateFlow()

    private val _generatedNsec = MutableStateFlow<String?>(null)
    val generatedNsec = _generatedNsec.asStateFlow()

    private val _isAmberAvailable = MutableStateFlow(false)
    val isAmberAvailable = _isAmberAvailable.asStateFlow()

    // Relays
    private val _wizardRelays = MutableStateFlow(
        listOf(
            "wss://relay.damus.io",
            "wss://relay.primal.net",
            "wss://nos.lol",
            "wss://relay.btcforplebs.com",
        )
    )
    val wizardRelays = _wizardRelays.asStateFlow()

    private val _newRelayInput = MutableStateFlow("")
    val newRelayInput = _newRelayInput.asStateFlow()

    private val _macRelayInput = MutableStateFlow("")
    val macRelayInput = _macRelayInput.asStateFlow()

    // Import
    private val _importStartDate = MutableStateFlow("2023-01-01")
    val importStartDate = _importStartDate.asStateFlow()

    private val _isImporting = MutableStateFlow(false)
    val isImporting = _isImporting.asStateFlow()

    private val _importProgress = MutableStateFlow(-1f) // -1 = indeterminate
    val importProgress = _importProgress.asStateFlow()

    private val _importStatus = MutableStateFlow("")
    val importStatus = _importStatus.asStateFlow()

    private val _importCompleted = MutableStateFlow(false)
    val importCompleted = _importCompleted.asStateFlow()

    // Blossom
    private val _blossomURL = MutableStateFlow("https://blossom.primal.net")
    val blossomURL = _blossomURL.asStateFlow()

    private val _isMirroring = MutableStateFlow(false)
    val isMirroring = _isMirroring.asStateFlow()

    private val _mirrorProgress = MutableStateFlow(-1f)
    val mirrorProgress = _mirrorProgress.asStateFlow()

    private val _mirrorStatus = MutableStateFlow("")
    val mirrorStatus = _mirrorStatus.asStateFlow()

    private val _mirrorCompleted = MutableStateFlow(false)
    val mirrorCompleted = _mirrorCompleted.asStateFlow()

    // Wallet
    private val _nwcInput = MutableStateFlow("")
    val nwcInput = _nwcInput.asStateFlow()

    private val _cashuInput = MutableStateFlow("")
    val cashuInput = _cashuInput.asStateFlow()

    init {
        _isAmberAvailable.value = amberSignerService.isAmberInstalled()
    }

    // ── Setters ──────────────────────────────────────────────────

    fun setSetupPath(path: SetupPath) { _setupPath.value = path }
    fun setAccountMode(mode: AccountMode) { _accountMode.value = mode }
    fun setNpubInput(value: String) { _npubInput.value = value; _error.value = null }
    fun setNsecInput(value: String) { _nsecInput.value = value; _error.value = null }
    fun setPassphrase(value: String) { _passphrase.value = value }
    fun setNewRelayInput(value: String) { _newRelayInput.value = value }
    fun setMacRelayInput(value: String) { _macRelayInput.value = value }
    fun setImportStartDate(value: String) { _importStartDate.value = value }
    fun setBlossomURL(value: String) { _blossomURL.value = value }
    fun setNwcInput(value: String) { _nwcInput.value = value }
    fun setCashuInput(value: String) { _cashuInput.value = value }

    // ── Navigation ───────────────────────────────────────────────

    /** Steps for full setup mode. */
    private val fullSteps = listOf(
        WizardStep.WELCOME, WizardStep.CHOOSE_PATH, WizardStep.ACCOUNT,
        WizardStep.RELAYS, WizardStep.IMPORT_NOTES, WizardStep.MIRROR_MEDIA,
        WizardStep.WALLET, WizardStep.COMPLETE,
    )

    /** Steps for browse mode. */
    private val browseSteps = listOf(
        WizardStep.WELCOME, WizardStep.CHOOSE_PATH, WizardStep.ACCOUNT,
        WizardStep.IMPORT_NOTES, WizardStep.COMPLETE,
    )

    /** Active step list based on current setup path. */
    val activeSteps: List<WizardStep>
        get() = if (_setupPath.value == SetupPath.BROWSE) browseSteps else fullSteps

    /** Current step index (0-based) within active step list. */
    val currentStepIndex: Int
        get() = activeSteps.indexOf(_step.value).coerceAtLeast(0)

    fun goBack() {
        val steps = activeSteps
        val idx = steps.indexOf(_step.value)
        if (idx > 0) _step.value = steps[idx - 1]
    }

    fun advanceFromWelcome() { _step.value = WizardStep.CHOOSE_PATH }

    fun advanceFromChoosePath() {
        _step.value = WizardStep.ACCOUNT
    }

    fun advanceFromAccount() {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                if (_setupPath.value == SetupPath.BROWSE) {
                    // Browse mode: npub, NIP-05, or nprofile
                    var input = _npubInput.value.trim()
                    // Strip nostr: prefix
                    if (input.startsWith("nostr:")) input = input.removePrefix("nostr:")

                    val resolvedNpub: String = when {
                        input.startsWith("npub1") -> {
                            // Validate npub
                            if (HavenBridge.decodeNpub(input) == null) {
                                _error.value = "Invalid npub key"
                                _isLoading.value = false
                                return@launch
                            }
                            input
                        }
                        input.startsWith("nprofile1") -> {
                            // Decode nprofile to get pubkey
                            val profileJson = HavenBridge.decodeNprofile(input)
                            if (profileJson == null) {
                                _error.value = "Invalid nprofile"
                                _isLoading.value = false
                                return@launch
                            }
                            val pubkey = JSONObject(profileJson).getString("pubkey")
                            HavenBridge.hexToNpub(pubkey) ?: run {
                                _error.value = "Failed to encode public key"
                                _isLoading.value = false
                                return@launch
                            }
                        }
                        input.contains("@") || (!input.startsWith("npub") && input.contains(".")) -> {
                            // NIP-05 resolution
                            val resolved = resolveNIP05(input)
                            if (resolved == null) {
                                _isLoading.value = false
                                return@launch // error already set
                            }
                            resolved
                        }
                        else -> {
                            _error.value = "Enter an npub or NIP-05 (user@domain.com)"
                            _isLoading.value = false
                            return@launch
                        }
                    }

                    configStore.update { it.copy(
                        ownerNpub = resolvedNpub,
                        setupMode = "browse",
                        signingMode = "browse",
                    ) }
                    _step.value = WizardStep.IMPORT_NOTES
                } else {
                    // Full mode
                    when (_accountMode.value) {
                        AccountMode.GENERATE -> {
                            val keypair = HavenBridge.generateKeypair() ?: run {
                                _error.value = "Key generation failed"
                                _isLoading.value = false
                                return@launch
                            }
                            val parts = keypair.split(":")
                            if (parts.size != 2) {
                                _error.value = "Key generation returned invalid format"
                                _isLoading.value = false
                                return@launch
                            }
                            val skHex = parts[0]
                            val pkHex = parts[1]
                            val npub = HavenBridge.hexToNpub(pkHex)
                            val nsec = HavenBridge.encodeNsec(skHex)
                            _generatedNsec.value = nsec
                            credentialStore.saveNsec(skHex, pkHex)
                            configStore.update { it.copy(
                                ownerNpub = npub ?: pkHex,
                                ownerHexKey = skHex,
                                signingMode = "local",
                                setupMode = "full",
                            ) }
                            configStore.setActiveAccount(pkHex)
                        }
                        AccountMode.IMPORT -> {
                            val nsec = _nsecInput.value.trim()
                            if (!nsec.startsWith("nsec1")) {
                                _error.value = "Key must start with nsec1"
                                _isLoading.value = false
                                return@launch
                            }
                            val skHex = HavenBridge.nsecToHex(nsec)
                            if (skHex == null) {
                                _error.value = "Invalid nsec key"
                                _isLoading.value = false
                                return@launch
                            }
                            val pkHex = HavenBridge.getPublicKey(skHex)
                            if (pkHex == null) {
                                _error.value = "Failed to derive public key"
                                _isLoading.value = false
                                return@launch
                            }
                            val npub = HavenBridge.hexToNpub(pkHex)
                            credentialStore.saveNsec(skHex, pkHex)
                            configStore.update { it.copy(
                                ownerNpub = npub ?: pkHex,
                                ownerHexKey = skHex,
                                signingMode = "local",
                                setupMode = "full",
                            ) }
                            configStore.setActiveAccount(pkHex)
                        }
                        AccountMode.AMBER -> {
                            val hexPubkey = amberSignerService.getPublicKey()
                            if (hexPubkey == null) {
                                _error.value = "Amber signing was cancelled or timed out"
                                _isLoading.value = false
                                return@launch
                            }
                            val npub = HavenBridge.hexToNpub(hexPubkey) ?: hexPubkey
                            configStore.update { it.copy(
                                ownerNpub = npub,
                                signingMode = "amber",
                                setupMode = "full",
                                amberSignerPackage = amberSignerService.signerPackage,
                            ) }
                            configStore.setActiveAccount(hexPubkey)
                        }
                    }
                    _step.value = WizardStep.RELAYS
                }
            } catch (e: Exception) {
                _error.value = e.message ?: "Setup failed"
            }
            _isLoading.value = false
        }
    }

    // ── NIP-05 Resolution ─────────────────────────────────────────

    /** Resolve a NIP-05 identifier to an npub. Returns null on failure (error is set). */
    private suspend fun resolveNIP05(input: String): String? = withContext(Dispatchers.IO) {
        try {
            val lowered = input.lowercase().trim()
            val user: String
            val domain: String
            if (lowered.contains("@")) {
                val parts = lowered.split("@", limit = 2)
                if (parts.size != 2 || parts[0].isEmpty() || parts[1].isEmpty()) {
                    _error.value = "Invalid NIP-05 format. Use user@domain.com"
                    return@withContext null
                }
                user = parts[0]
                domain = parts[1]
            } else {
                // Bare domain — implies _@domain
                user = "_"
                domain = lowered
            }

            if (!domain.contains(".")) {
                _error.value = "Invalid NIP-05 format. Use user@domain.com"
                return@withContext null
            }

            val url = URL("https://$domain/.well-known/nostr.json?name=$user")
            val responseText = url.readText()
            val json = JSONObject(responseText)
            val names = json.optJSONObject("names")
            if (names == null) {
                _error.value = "Name not found on that domain"
                return@withContext null
            }

            val hexPubkey = names.optString(user)
            if (hexPubkey.isNullOrEmpty() || hexPubkey.length != 64) {
                _error.value = "Name not found on that domain"
                return@withContext null
            }

            val npub = HavenBridge.hexToNpub(hexPubkey)
            if (npub == null) {
                _error.value = "Server returned an invalid public key"
                return@withContext null
            }

            npub
        } catch (e: Exception) {
            _error.value = "Could not resolve NIP-05: ${e.localizedMessage ?: "Network error"}"
            null
        }
    }

    // ── Relays ───────────────────────────────────────────────────

    fun addWizardRelay() {
        val url = _newRelayInput.value.trim()
        if (url.isBlank() || !url.startsWith("wss://")) return
        if (url in _wizardRelays.value) return
        _wizardRelays.value = _wizardRelays.value + url
        _newRelayInput.value = ""
    }

    fun removeWizardRelay(url: String) {
        _wizardRelays.value = _wizardRelays.value - url
    }

    fun advanceFromRelays() {
        configStore.update { it.copy(
            inboxRelays = _wizardRelays.value,
            feedRelays = _wizardRelays.value,
            macRelayURL = _macRelayInput.value.trim(),
        ) }
        _step.value = WizardStep.IMPORT_NOTES
    }

    // ── Import ───────────────────────────────────────────────────

    fun startNetworkImport() {
        if (_isImporting.value) return
        viewModelScope.launch {
            // Persist the selected import start date to config
            configStore.update { it.copy(importStartDate = _importStartDate.value) }

            _isImporting.value = true
            _importProgress.value = -1f
            _importStatus.value = "Setting up import..."
            _importCompleted.value = false

            // Poll Go relay logs in the background so the UI shows progress
            val pollJob = launch(Dispatchers.Default) {
                while (true) {
                    try {
                        val logLine = HavenBridge.getImportLog()
                        if (logLine != null) {
                            _importStatus.value = logLine
                        }
                    } catch (_: Exception) { }
                    kotlinx.coroutines.delay(400)
                }
            }

            withContext(Dispatchers.IO) {
                try {
                    if (!HavenBridge.isLoaded) {
                        _importStatus.value = "Native library not loaded"
                        _isImporting.value = false
                        return@withContext
                    }

                    val relayDataDir = File(appContext.filesDir, "relay_data")
                    RelayConfiguration.ensureDirectories(relayDataDir)

                    val config = configStore.config.value
                    val envDict = RelayConfiguration.generateEnvDictionary(
                        config = config,
                        relayDataDir = relayDataDir,
                    )
                    for ((key, value) in envDict) {
                        HavenBridge.setEnv(key, value)
                    }

                    // Write seed relays JSON and set env to ABSOLUTE path
                    val seedRelaysFile = File(relayDataDir, "relays_import.json")
                    val seedRelays = config.importSeedRelays
                    val relaysJson = buildString {
                        append("[")
                        append(seedRelays.joinToString(",") { "\"$it\"" })
                        append("]")
                    }
                    seedRelaysFile.writeText(relaysJson)
                    HavenBridge.setEnv("IMPORT_SEED_RELAYS_FILE", seedRelaysFile.absolutePath)

                    // Also fix other file-based env vars that need absolute paths
                    val blastrFile = File(relayDataDir, config.blastrRelaysFile)
                    if (!blastrFile.exists()) {
                        val blastrJson = buildString {
                            append("[")
                            append(config.blastrRelays.joinToString(",") { "\"$it\"" })
                            append("]")
                        }
                        blastrFile.writeText(blastrJson)
                    }
                    HavenBridge.setEnv("BLASTR_RELAYS_FILE", blastrFile.absolutePath)

                    // Ensure import start date is set
                    val startDate = config.importStartDate.ifEmpty { "2023-01-01" }
                    HavenBridge.setEnv("IMPORT_START_DATE", startDate)

                    // startRelay(importMode = true) is blocking -- pollJob
                    // feeds Go log output to _importStatus while this runs
                    HavenBridge.startRelay(importMode = true)

                    _importCompleted.value = true
                    _importStatus.value = "Import complete"
                } catch (e: Exception) {
                    _importStatus.value = "Import failed: ${e.message}"
                }
                _isImporting.value = false
            }

            pollJob.cancel()
        }
    }

    fun restoreFromBackup(zipPath: String) {
        if (_isImporting.value) return
        viewModelScope.launch {
            _isImporting.value = true
            _importStatus.value = "Restoring from backup..."
            _importCompleted.value = false

            withContext(Dispatchers.IO) {
                try {
                    val result = HavenBridge.restoreDatabase(zipPath)
                    if (result == 0) {
                        _importCompleted.value = true
                        _importStatus.value = "Restore complete"
                    } else {
                        _importStatus.value = "Restore failed (code $result)"
                    }
                } catch (e: Exception) {
                    _importStatus.value = "Restore failed: ${e.message}"
                }
                _isImporting.value = false
            }
        }
    }

    fun cancelImport() {
        viewModelScope.launch(Dispatchers.IO) {
            try { HavenBridge.stopRelay() } catch (_: Exception) {}
        }
    }

    fun advanceFromImport() {
        _step.value = if (_setupPath.value == SetupPath.BROWSE) WizardStep.COMPLETE else WizardStep.MIRROR_MEDIA
    }
    fun skipImport() {
        _step.value = if (_setupPath.value == SetupPath.BROWSE) WizardStep.COMPLETE else WizardStep.MIRROR_MEDIA
    }

    // ── Blossom ──────────────────────────────────────────────────

    fun startMediaMirror() {
        if (_isMirroring.value) return
        viewModelScope.launch {
            _isMirroring.value = true
            _mirrorProgress.value = -1f
            _mirrorStatus.value = "Starting media sync..."
            _mirrorCompleted.value = false

            // Save mirror URL to config first
            val url = _blossomURL.value.trim()
            if (url.isNotEmpty()) {
                configStore.update { config ->
                    if (url !in config.blossomMirrors) {
                        config.copy(blossomMirrors = config.blossomMirrors + url)
                    } else config
                }
            }

            try {
                blossomService.mirrorAllFromExternal(
                    onProgress = { progress ->
                        _mirrorProgress.value = progress
                    },
                    onLogMessage = { message ->
                        _mirrorStatus.value = message
                    },
                )
                _mirrorCompleted.value = true
                _mirrorStatus.value = "Media sync complete"
            } catch (e: Exception) {
                _mirrorStatus.value = "Sync failed: ${e.message}"
            }
            _isMirroring.value = false
        }
    }

    fun importMediaArchive(zipPath: String) {
        if (_isMirroring.value) return
        viewModelScope.launch {
            _isMirroring.value = true
            _mirrorStatus.value = "Extracting media archive..."
            _mirrorCompleted.value = false

            withContext(Dispatchers.IO) {
                try {
                    val relayDataDir = File(appContext.filesDir, "relay_data")
                    val blossomDir = File(relayDataDir, "blossom")
                    blossomDir.mkdirs()
                    val result = HavenBridge.unzipDirectory(zipPath, blossomDir.absolutePath)
                    if (result == 0) {
                        _mirrorCompleted.value = true
                        _mirrorStatus.value = "Media import complete"
                    } else {
                        _mirrorStatus.value = "Import failed (code $result)"
                    }
                } catch (e: Exception) {
                    _mirrorStatus.value = "Import failed: ${e.message}"
                }
                _isMirroring.value = false
            }
        }
    }

    fun advanceFromMedia() { _step.value = WizardStep.WALLET }
    fun skipMedia() { _step.value = WizardStep.WALLET }

    // ── Wallet ───────────────────────────────────────────────────

    fun advanceFromWallet() {
        val nwc = _nwcInput.value.trim().ifEmpty { null }
        val cashu = _cashuInput.value.trim()
        configStore.update { it.copy(
            nwcURI = nwc,
            cashuMintURL = cashu,
        ) }
        _step.value = WizardStep.COMPLETE
    }

    fun skipWallet() { _step.value = WizardStep.COMPLETE }

    // ── Complete ─────────────────────────────────────────────────

    fun completeSetup(onComplete: () -> Unit) {
        viewModelScope.launch {
            configStore.update { it.copy(hasCompletedSetup = true) }

            // Resolve active account hex pubkey (matches iOS refreshActiveAccountHex)
            val npub = configStore.config.value.ownerNpub
            if (npub.startsWith("npub1")) {
                try {
                    val hex = HavenBridge.decodeNpub(npub)
                    if (!hex.isNullOrEmpty()) {
                        configStore.setActiveAccount(hex)
                    }
                } catch (_: Exception) {}
            }

            onComplete()
        }
    }
}

// ══════════════════════════════════════════════════════════════════
// Screen
// ══════════════════════════════════════════════════════════════════

@Composable
fun SetupWizardScreen(
    onComplete: () -> Unit,
    viewModel: SetupWizardViewModel = hiltViewModel(),
) {
    val step by viewModel.step.collectAsState()
    val setupPath by viewModel.setupPath.collectAsState()
    val scrollState = rememberScrollState()

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(WizardBgPrimary),
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(scrollState)
                .padding(horizontal = 24.dp)
                .statusBarsPadding()
                .navigationBarsPadding(),
        ) {
            Spacer(Modifier.height(32.dp))

            // Back button (hidden on first step)
            if (step != WizardStep.WELCOME) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.Start,
                ) {
                    IconButton(onClick = viewModel::goBack) {
                        Icon(
                            imageVector = NostrVaultIcons.Back,
                            contentDescription = "Back",
                            tint = SecondaryText,
                        )
                    }
                }
            } else {
                Spacer(Modifier.height(48.dp))
            }

            // App brand
            Text(
                text = "Nostr Vault",
                color = WizardAccent,
                fontSize = 32.sp,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = "Your personal relay",
                color = SecondaryText,
                fontSize = 16.sp,
            )

            // Step dots
            if (step != WizardStep.WELCOME) {
                Spacer(Modifier.height(16.dp))
                StepDots(
                    totalSteps = viewModel.activeSteps.size,
                    currentIndex = viewModel.currentStepIndex,
                )
            }

            Spacer(Modifier.height(32.dp))

            AnimatedContent(
                targetState = step,
                transitionSpec = {
                    (slideInHorizontally { it } + fadeIn()).togetherWith(
                        slideOutHorizontally { -it } + fadeOut()
                    )
                },
                label = "wizard_step",
            ) { currentStep ->
                when (currentStep) {
                    WizardStep.WELCOME -> WelcomeStep(
                        onContinue = viewModel::advanceFromWelcome,
                    )
                    WizardStep.CHOOSE_PATH -> ChoosePathStep(viewModel)
                    WizardStep.ACCOUNT -> AccountStep(viewModel)
                    WizardStep.RELAYS -> RelayStep(viewModel)
                    WizardStep.IMPORT_NOTES -> ImportNotesStep(viewModel)
                    WizardStep.MIRROR_MEDIA -> MirrorMediaStep(viewModel)
                    WizardStep.WALLET -> WalletSetupStep(viewModel)
                    WizardStep.COMPLETE -> CompleteStep(
                        setupPath = setupPath,
                        onFinish = { viewModel.completeSetup(onComplete) },
                    )
                }
            }

            Spacer(Modifier.height(48.dp))
        }
    }
}

// ══════════════════════════════════════════════════════════════════
// Step Dots
// ══════════════════════════════════════════════════════════════════

@Composable
private fun StepDots(totalSteps: Int, currentIndex: Int) {
    Row(
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        for (i in 0 until totalSteps) {
            Box(
                modifier = Modifier
                    .size(if (i == currentIndex) 10.dp else 8.dp)
                    .clip(CircleShape)
                    .background(
                        when {
                            i < currentIndex -> WizardAccent.copy(alpha = 0.4f)
                            i == currentIndex -> WizardAccent
                            else -> WizardBorderSubtle
                        }
                    ),
            )
            if (i < totalSteps - 1) {
                Spacer(Modifier.width(8.dp))
            }
        }
    }
}

// ══════════════════════════════════════════════════════════════════
// Step 1: Welcome
// ══════════════════════════════════════════════════════════════════

@Composable
private fun WelcomeStep(onContinue: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        WizardCard {
            Text(
                text = "Take control of your social data",
                color = PrimaryText,
                fontSize = 20.sp,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(12.dp))
            Text(
                text = "Nostr Vault runs a personal relay on your device. Your notes, messages, and media stay with you -- not on someone else's server.",
                color = SecondaryText,
                fontSize = 15.sp,
                lineHeight = 22.sp,
                textAlign = TextAlign.Center,
            )
        }

        Spacer(Modifier.height(24.dp))

        val features = listOf(
            "Personal Relay" to "Run your own relay on-device",
            "Full Nostr Client" to "Browse, post, reply, discover",
            "Private Messaging" to "NIP-17 encrypted DMs",
            "Blossom Media" to "Host images/videos on your device",
            "Lightning + Ecash" to "Send/receive zaps with NWC and Cashu",
        )
        for ((title, desc) in features) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 6.dp),
            ) {
                Text("*", color = WizardAccent, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.width(12.dp))
                Column {
                    Text(title, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.Medium)
                    Text(desc, color = SecondaryText, fontSize = 13.sp)
                }
            }
        }

        Spacer(Modifier.height(32.dp))

        WizardPrimaryButton(text = "Get Started", onClick = onContinue)
    }
}

// ══════════════════════════════════════════════════════════════════
// Step 2: Choose Path
// ══════════════════════════════════════════════════════════════════

@Composable
private fun ChoosePathStep(viewModel: SetupWizardViewModel) {
    val setupPath by viewModel.setupPath.collectAsState()

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = "Choose your setup",
            color = PrimaryText,
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "You can upgrade from browse mode later.",
            color = SecondaryText,
            fontSize = 14.sp,
        )

        Spacer(Modifier.height(24.dp))

        WizardOptionCard(
            title = "Full Setup",
            subtitle = "Relay, notes, media, wallet -- the complete package",
            selected = setupPath == SetupPath.FULL,
            onClick = { viewModel.setSetupPath(SetupPath.FULL) },
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(Modifier.height(12.dp))

        WizardOptionCard(
            title = "Browse Mode",
            subtitle = "Read-only browsing -- no private key needed",
            selected = setupPath == SetupPath.BROWSE,
            onClick = { viewModel.setSetupPath(SetupPath.BROWSE) },
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(Modifier.height(32.dp))

        WizardPrimaryButton(
            text = "Continue",
            enabled = setupPath != SetupPath.NONE,
            onClick = viewModel::advanceFromChoosePath,
        )
    }
}

// ══════════════════════════════════════════════════════════════════
// Step 3: Account
// ══════════════════════════════════════════════════════════════════

@Composable
private fun AccountStep(viewModel: SetupWizardViewModel) {
    val setupPath by viewModel.setupPath.collectAsState()
    val mode by viewModel.accountMode.collectAsState()
    val npubInput by viewModel.npubInput.collectAsState()
    val nsecInput by viewModel.nsecInput.collectAsState()
    val error by viewModel.error.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val generatedNsec by viewModel.generatedNsec.collectAsState()
    val isAmberAvailable by viewModel.isAmberAvailable.collectAsState()
    val focusManager = LocalFocusManager.current

    // QR scanner launcher
    val qrLauncher = rememberLauncherForActivityResult(ScanContract()) { result ->
        result.contents?.let { scanned ->
            val cleaned = if (scanned.startsWith("nostr:")) scanned.removePrefix("nostr:") else scanned
            viewModel.setNpubInput(cleaned)
        }
    }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = if (setupPath == SetupPath.BROWSE) "Enter your identity" else "Set up your account",
            color = PrimaryText,
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(20.dp))

        if (setupPath == SetupPath.BROWSE) {
            // Browse mode: npub, NIP-05, or QR
            Text(
                text = "Enter your npub, NIP-05 (user@domain), or scan a QR code.",
                color = SecondaryText,
                fontSize = 14.sp,
                lineHeight = 20.sp,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(16.dp))
            OutlinedTextField(
                value = npubInput,
                onValueChange = viewModel::setNpubInput,
                label = { Text("npub1... or user@domain.com") },
                isError = error != null,
                supportingText = error?.let { { Text(it, color = ErrorRed) } },
                singleLine = true,
                trailingIcon = {
                    IconButton(onClick = {
                        qrLauncher.launch(
                            ScanOptions().apply {
                                setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                                setPrompt("Scan a Nostr QR code")
                                setBeepEnabled(false)
                                setOrientationLocked(true)
                            }
                        )
                    }) {
                        Icon(
                            Icons.Default.QrCodeScanner,
                            contentDescription = "Scan QR code",
                            tint = WizardAccent,
                        )
                    }
                },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
                colors = wizardTextFieldColors(),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(24.dp))
            WizardPrimaryButton(
                text = if (npubInput.contains("@") || (!npubInput.startsWith("npub") && npubInput.contains(".")))
                    "Resolve & Continue" else "Continue",
                enabled = !isLoading && npubInput.isNotBlank(),
                isLoading = isLoading,
                onClick = viewModel::advanceFromAccount,
            )
        } else {
            // Full mode: Generate / Import / Amber
            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                WizardOptionCard(
                    title = "Generate New",
                    subtitle = "Create a new Nostr identity",
                    selected = mode == AccountMode.GENERATE,
                    onClick = { viewModel.setAccountMode(AccountMode.GENERATE) },
                    modifier = Modifier.weight(1f),
                )
                WizardOptionCard(
                    title = "Import Key",
                    subtitle = "Use an existing nsec",
                    selected = mode == AccountMode.IMPORT,
                    onClick = { viewModel.setAccountMode(AccountMode.IMPORT) },
                    modifier = Modifier.weight(1f),
                )
            }

            if (isAmberAvailable) {
                Spacer(Modifier.height(12.dp))
                WizardOptionCard(
                    title = "Use Amber Signer",
                    subtitle = "Sign events with the Amber app (NIP-55)",
                    selected = mode == AccountMode.AMBER,
                    onClick = { viewModel.setAccountMode(AccountMode.AMBER) },
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            Spacer(Modifier.height(24.dp))

            AnimatedVisibility(visible = mode == AccountMode.IMPORT) {
                Column {
                    OutlinedTextField(
                        value = nsecInput,
                        onValueChange = viewModel::setNsecInput,
                        label = { Text("nsec1...") },
                        visualTransformation = PasswordVisualTransformation(),
                        isError = error != null,
                        supportingText = error?.let { { Text(it, color = ErrorRed) } },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
                        colors = wizardTextFieldColors(),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(16.dp))
                }
            }

            AnimatedVisibility(visible = mode == AccountMode.AMBER) {
                Column {
                    Text(
                        text = "Amber will handle all event signing. Your private key stays in Amber -- Nostr Vault never sees it.",
                        color = SecondaryText,
                        fontSize = 14.sp,
                        lineHeight = 20.sp,
                        textAlign = TextAlign.Center,
                    )
                    Spacer(Modifier.height(16.dp))
                }
            }

            error?.let { errorText ->
                if (mode != AccountMode.IMPORT) {
                    Text(errorText, color = ErrorRed, fontSize = 13.sp)
                    Spacer(Modifier.height(8.dp))
                }
            }

            WizardPrimaryButton(
                text = when (mode) {
                    AccountMode.GENERATE -> "Generate Keypair"
                    AccountMode.IMPORT -> "Import Key"
                    AccountMode.AMBER -> "Connect Amber"
                },
                enabled = !isLoading && (mode != AccountMode.IMPORT || nsecInput.isNotBlank()),
                isLoading = isLoading,
                onClick = viewModel::advanceFromAccount,
            )
        }
    }
}

// ══════════════════════════════════════════════════════════════════
// Step 4: Relay Configuration (editable)
// ══════════════════════════════════════════════════════════════════

@Composable
private fun RelayStep(viewModel: SetupWizardViewModel) {
    val relays by viewModel.wizardRelays.collectAsState()
    val newRelayInput by viewModel.newRelayInput.collectAsState()
    val macRelayInput by viewModel.macRelayInput.collectAsState()
    val focusManager = LocalFocusManager.current

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = "Relay Configuration",
            color = PrimaryText,
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "These relays will be used for your feed. Your personal relay also runs on-device.",
            color = SecondaryText,
            fontSize = 14.sp,
            textAlign = TextAlign.Center,
        )

        Spacer(Modifier.height(20.dp))

        // Mac relay section
        WizardCard {
            Column(modifier = Modifier.padding(4.dp)) {
                Text(
                    text = "Sync with Mac Relay",
                    color = PrimaryText,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Medium,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = "If you run Haven on your Mac, enter its relay URL to stay synced.",
                    color = SecondaryText,
                    fontSize = 13.sp,
                )
                Spacer(Modifier.height(10.dp))
                OutlinedTextField(
                    value = macRelayInput,
                    onValueChange = viewModel::setMacRelayInput,
                    placeholder = { Text("wss://relay.yourdomain.com", color = TertiaryText) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
                    colors = wizardTextFieldColors(),
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = "You can find this in Haven settings on your Mac. Leave blank to skip.",
                    color = TertiaryText,
                    fontSize = 11.sp,
                )
            }
        }

        Spacer(Modifier.height(20.dp))

        // Add relay input
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            OutlinedTextField(
                value = newRelayInput,
                onValueChange = viewModel::setNewRelayInput,
                placeholder = { Text("wss://relay.example.com", color = TertiaryText) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = {
                    viewModel.addWizardRelay()
                    focusManager.clearFocus()
                }),
                colors = wizardTextFieldColors(),
                shape = RoundedCornerShape(8.dp),
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(8.dp))
            IconButton(
                onClick = viewModel::addWizardRelay,
                enabled = newRelayInput.isNotBlank(),
            ) {
                Icon(
                    imageVector = NostrVaultIcons.Create,
                    contentDescription = "Add",
                    tint = if (newRelayInput.isNotBlank()) WizardAccent else TertiaryText,
                )
            }
        }

        Spacer(Modifier.height(12.dp))

        // Relay list
        WizardCard {
            if (relays.isEmpty()) {
                Text(
                    text = "No relays configured",
                    color = SecondaryText,
                    fontSize = 14.sp,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
                )
            } else {
                for ((index, relay) in relays.withIndex()) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 6.dp),
                    ) {
                        Icon(
                            imageVector = NostrVaultIcons.Domain,
                            contentDescription = null,
                            tint = WizardAccent,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.width(10.dp))
                        Text(
                            text = relay.removePrefix("wss://"),
                            color = PrimaryText,
                            fontSize = 14.sp,
                            modifier = Modifier.weight(1f),
                        )
                        IconButton(
                            onClick = { viewModel.removeWizardRelay(relay) },
                            modifier = Modifier.size(32.dp),
                        ) {
                            Icon(
                                imageVector = NostrVaultIcons.Dismiss,
                                contentDescription = "Remove",
                                tint = ErrorRed,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                    }
                    if (index < relays.lastIndex) {
                        HorizontalDivider(
                            color = WizardBorderSubtle,
                            thickness = 0.5.dp,
                            modifier = Modifier.padding(start = 28.dp),
                        )
                    }
                }
            }
        }

        Spacer(Modifier.height(32.dp))
        WizardPrimaryButton(text = "Continue", onClick = viewModel::advanceFromRelays)
    }
}

// ══════════════════════════════════════════════════════════════════
// Step 5: Import Notes
// ══════════════════════════════════════════════════════════════════

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ImportNotesStep(viewModel: SetupWizardViewModel) {
    val isImporting by viewModel.isImporting.collectAsState()
    val importStatus by viewModel.importStatus.collectAsState()
    val importCompleted by viewModel.importCompleted.collectAsState()
    val importStartDate by viewModel.importStartDate.collectAsState()
    val context = LocalContext.current

    var selectedTab by remember { mutableIntStateOf(0) }
    val tabs = listOf("Network", "Backup")
    var showDatePicker by remember { mutableStateOf(false) }

    // File picker for backup restore
    val backupPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri ->
        uri?.let {
            // Copy to temp file for JNI access
            val tempFile = File(context.cacheDir, "restore_backup.zip")
            context.contentResolver.openInputStream(it)?.use { input ->
                tempFile.outputStream().use { output -> input.copyTo(output) }
            }
            viewModel.restoreFromBackup(tempFile.absolutePath)
        }
    }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = "Import Notes",
            color = PrimaryText,
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "Bring your existing notes into your personal relay.",
            color = SecondaryText,
            fontSize = 14.sp,
            textAlign = TextAlign.Center,
        )

        Spacer(Modifier.height(20.dp))

        // Tab selector
        WizardTabRow(tabs = tabs, selectedTab = selectedTab, onTabSelected = { selectedTab = it })

        Spacer(Modifier.height(16.dp))

        AnimatedContent(
            targetState = selectedTab,
            label = "import_tab",
        ) { tab ->
            when (tab) {
                0 -> {
                    // Network import
                    WizardCard {
                        Text(
                            text = "Import from Network",
                            color = PrimaryText,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(Modifier.height(8.dp))
                        Text(
                            text = "Fetch your notes from public relays and store them locally.",
                            color = SecondaryText,
                            fontSize = 14.sp,
                            lineHeight = 20.sp,
                        )

                        if (importStatus.isNotEmpty()) {
                            Spacer(Modifier.height(12.dp))
                            Text(
                                text = importStatus,
                                color = if (importCompleted) SuccessGreen else SecondaryText,
                                fontSize = 13.sp,
                            )
                        }

                        if (isImporting) {
                            Spacer(Modifier.height(12.dp))
                            LinearProgressIndicator(
                                color = WizardAccent,
                                trackColor = WizardBgElevated,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }

                        if (!isImporting && !importCompleted) {
                            Spacer(Modifier.height(12.dp))
                            HorizontalDivider(color = WizardBorderSubtle)
                            Spacer(Modifier.height(12.dp))

                            // Date picker row
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(8.dp))
                                    .clickable { showDatePicker = true }
                                    .padding(vertical = 8.dp),
                            ) {
                                Text(
                                    text = "Import from",
                                    color = SecondaryText,
                                    fontSize = 14.sp,
                                )
                                Spacer(Modifier.weight(1f))
                                Text(
                                    text = importStartDate,
                                    color = WizardAccent,
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.Medium,
                                )
                            }
                        }

                        Spacer(Modifier.height(16.dp))

                        if (!isImporting && !importCompleted) {
                            WizardPrimaryButton(
                                text = "Import Notes",
                                onClick = viewModel::startNetworkImport,
                            )
                        } else if (isImporting) {
                            WizardSecondaryButton(
                                text = "Cancel",
                                onClick = viewModel::cancelImport,
                            )
                        }
                    }
                }
                1 -> {
                    // Backup restore
                    WizardCard {
                        Text(
                            text = "Restore from Backup",
                            color = PrimaryText,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(Modifier.height(8.dp))
                        Text(
                            text = "Restore from a previous Nostr Vault backup file (.zip).",
                            color = SecondaryText,
                            fontSize = 14.sp,
                            lineHeight = 20.sp,
                        )

                        if (importStatus.isNotEmpty()) {
                            Spacer(Modifier.height(12.dp))
                            Text(
                                text = importStatus,
                                color = if (importCompleted) SuccessGreen else SecondaryText,
                                fontSize = 13.sp,
                            )
                        }

                        if (isImporting) {
                            Spacer(Modifier.height(12.dp))
                            LinearProgressIndicator(
                                color = WizardAccent,
                                trackColor = WizardBgElevated,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }

                        Spacer(Modifier.height(16.dp))

                        if (!isImporting && !importCompleted) {
                            WizardPrimaryButton(
                                text = "Choose Backup File",
                                onClick = {
                                    backupPicker.launch(arrayOf(
                                        "application/zip",
                                        "application/x-zip-compressed",
                                    ))
                                },
                            )
                        }
                    }
                }
            }
        }

        Spacer(Modifier.height(24.dp))

        if (importCompleted) {
            WizardPrimaryButton(text = "Continue", onClick = viewModel::advanceFromImport)
        } else if (!isImporting) {
            WizardSecondaryButton(text = "Skip", onClick = viewModel::skipImport)
        }
    }

    // Date picker dialog
    if (showDatePicker) {
        val datePickerState = rememberDatePickerState(
            initialSelectedDateMillis = try {
                java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).let { fmt ->
                    fmt.timeZone = java.util.TimeZone.getTimeZone("UTC")
                    fmt.parse(importStartDate)?.time ?: 0L
                }
            } catch (_: Exception) { 0L }
        )
        DatePickerDialog(
            onDismissRequest = { showDatePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    datePickerState.selectedDateMillis?.let { millis ->
                        val fmt = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
                        fmt.timeZone = java.util.TimeZone.getTimeZone("UTC")
                        viewModel.setImportStartDate(fmt.format(java.util.Date(millis)))
                    }
                    showDatePicker = false
                }) { Text("OK") }
            },
            dismissButton = {
                TextButton(onClick = { showDatePicker = false }) { Text("Cancel") }
            },
        ) {
            DatePicker(state = datePickerState)
        }
    }
}

// ══════════════════════════════════════════════════════════════════
// Step 6: Mirror Media (Blossom)
// ══════════════════════════════════════════════════════════════════

@Composable
private fun MirrorMediaStep(viewModel: SetupWizardViewModel) {
    val blossomURL by viewModel.blossomURL.collectAsState()
    val isMirroring by viewModel.isMirroring.collectAsState()
    val mirrorProgress by viewModel.mirrorProgress.collectAsState()
    val mirrorStatus by viewModel.mirrorStatus.collectAsState()
    val mirrorCompleted by viewModel.mirrorCompleted.collectAsState()
    val context = LocalContext.current

    var selectedTab by remember { mutableIntStateOf(0) }
    val tabs = listOf("Server Sync", "Backup")

    // File picker for media archive
    val mediaPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri ->
        uri?.let {
            val tempFile = File(context.cacheDir, "media_import.zip")
            context.contentResolver.openInputStream(it)?.use { input ->
                tempFile.outputStream().use { output -> input.copyTo(output) }
            }
            viewModel.importMediaArchive(tempFile.absolutePath)
        }
    }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = "Mirror Media",
            color = PrimaryText,
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "Sync your media from an external Blossom server to your device.",
            color = SecondaryText,
            fontSize = 14.sp,
            textAlign = TextAlign.Center,
        )

        Spacer(Modifier.height(20.dp))

        WizardTabRow(tabs = tabs, selectedTab = selectedTab, onTabSelected = { selectedTab = it })

        Spacer(Modifier.height(16.dp))

        AnimatedContent(
            targetState = selectedTab,
            label = "media_tab",
        ) { tab ->
            when (tab) {
                0 -> {
                    // Server sync
                    WizardCard {
                        Text(
                            text = "Sync from Blossom Server",
                            color = PrimaryText,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(Modifier.height(12.dp))
                        OutlinedTextField(
                            value = blossomURL,
                            onValueChange = viewModel::setBlossomURL,
                            label = { Text("Blossom server URL") },
                            singleLine = true,
                            colors = wizardTextFieldColors(),
                            modifier = Modifier.fillMaxWidth(),
                        )

                        if (mirrorStatus.isNotEmpty()) {
                            Spacer(Modifier.height(12.dp))
                            Text(
                                text = mirrorStatus,
                                color = if (mirrorCompleted) SuccessGreen else SecondaryText,
                                fontSize = 13.sp,
                            )
                        }

                        if (isMirroring) {
                            Spacer(Modifier.height(12.dp))
                            if (mirrorProgress >= 0f) {
                                LinearProgressIndicator(
                                    progress = { mirrorProgress },
                                    color = WizardAccent,
                                    trackColor = WizardBgElevated,
                                    modifier = Modifier.fillMaxWidth(),
                                )
                            } else {
                                LinearProgressIndicator(
                                    color = WizardAccent,
                                    trackColor = WizardBgElevated,
                                    modifier = Modifier.fillMaxWidth(),
                                )
                            }
                        }

                        Spacer(Modifier.height(16.dp))

                        if (!isMirroring && !mirrorCompleted) {
                            WizardPrimaryButton(
                                text = "Start Sync",
                                enabled = blossomURL.isNotBlank(),
                                onClick = viewModel::startMediaMirror,
                            )
                        }
                    }
                }
                1 -> {
                    // Backup import
                    WizardCard {
                        Text(
                            text = "Import Media Archive",
                            color = PrimaryText,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(Modifier.height(8.dp))
                        Text(
                            text = "Import a media archive (.zip) from a previous backup.",
                            color = SecondaryText,
                            fontSize = 14.sp,
                            lineHeight = 20.sp,
                        )

                        if (mirrorStatus.isNotEmpty()) {
                            Spacer(Modifier.height(12.dp))
                            Text(
                                text = mirrorStatus,
                                color = if (mirrorCompleted) SuccessGreen else SecondaryText,
                                fontSize = 13.sp,
                            )
                        }

                        if (isMirroring) {
                            Spacer(Modifier.height(12.dp))
                            LinearProgressIndicator(
                                color = WizardAccent,
                                trackColor = WizardBgElevated,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }

                        Spacer(Modifier.height(16.dp))

                        if (!isMirroring && !mirrorCompleted) {
                            WizardPrimaryButton(
                                text = "Choose Archive",
                                onClick = {
                                    mediaPicker.launch(arrayOf(
                                        "application/zip",
                                        "application/x-zip-compressed",
                                    ))
                                },
                            )
                        }
                    }
                }
            }
        }

        Spacer(Modifier.height(24.dp))

        if (mirrorCompleted) {
            WizardPrimaryButton(text = "Continue", onClick = viewModel::advanceFromMedia)
        } else if (!isMirroring) {
            WizardSecondaryButton(text = "Skip", onClick = viewModel::skipMedia)
        }
    }
}

// ══════════════════════════════════════════════════════════════════
// Step 7: Wallet Setup
// ══════════════════════════════════════════════════════════════════

@Composable
private fun WalletSetupStep(viewModel: SetupWizardViewModel) {
    val nwcInput by viewModel.nwcInput.collectAsState()
    val cashuInput by viewModel.cashuInput.collectAsState()
    val focusManager = LocalFocusManager.current

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = "Wallet Setup",
            color = PrimaryText,
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "Connect a Lightning wallet and/or Cashu mint. Both are optional.",
            color = SecondaryText,
            fontSize = 14.sp,
            textAlign = TextAlign.Center,
        )

        Spacer(Modifier.height(20.dp))

        // NWC section
        WizardCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = NostrVaultIcons.Zap,
                    contentDescription = null,
                    tint = WizardAccent,
                    modifier = Modifier.size(20.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    text = "Lightning (NWC)",
                    color = PrimaryText,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                value = nwcInput,
                onValueChange = viewModel::setNwcInput,
                placeholder = { Text("nostr+walletconnect://...", color = TertiaryText) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
                colors = wizardTextFieldColors(),
                modifier = Modifier.fillMaxWidth(),
            )
        }

        Spacer(Modifier.height(16.dp))

        // Cashu section
        WizardCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = NostrVaultIcons.Wallet,
                    contentDescription = null,
                    tint = WizardAccent,
                    modifier = Modifier.size(20.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    text = "Cashu Ecash",
                    color = PrimaryText,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                value = cashuInput,
                onValueChange = viewModel::setCashuInput,
                placeholder = { Text("https://mint.example.com", color = TertiaryText) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
                colors = wizardTextFieldColors(),
                modifier = Modifier.fillMaxWidth(),
            )
        }

        Spacer(Modifier.height(32.dp))

        if (nwcInput.isNotBlank() || cashuInput.isNotBlank()) {
            WizardPrimaryButton(text = "Save & Continue", onClick = viewModel::advanceFromWallet)
        } else {
            WizardSecondaryButton(text = "Skip", onClick = viewModel::skipWallet)
        }
    }
}

// ══════════════════════════════════════════════════════════════════
// Step 8: Complete
// ══════════════════════════════════════════════════════════════════

@Composable
private fun CompleteStep(
    setupPath: SetupPath,
    onFinish: () -> Unit,
) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        WizardCard {
            Text(
                text = "You're all set!",
                color = WizardAccent,
                fontSize = 24.sp,
                fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(16.dp))

            if (setupPath == SetupPath.BROWSE) {
                WizardCheckItem("Connected to Nostr")
                Spacer(Modifier.height(16.dp))
                Text(
                    text = "You're in browse mode. Upgrade to full setup for signing, your own relay, and media storage.",
                    color = SecondaryText,
                    fontSize = 14.sp,
                    lineHeight = 20.sp,
                    textAlign = TextAlign.Center,
                )
            } else {
                WizardCheckItem("Relay is running")
                WizardCheckItem("DMs enabled")
                WizardCheckItem("Blossom media active")
                WizardCheckItem("Posts being broadcast")
            }
        }

        Spacer(Modifier.height(32.dp))
        WizardPrimaryButton(text = "Open Nostr Vault", onClick = onFinish)
    }
}

@Composable
private fun WizardCheckItem(text: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
    ) {
        Icon(
            imageVector = NostrVaultIcons.Check,
            contentDescription = null,
            tint = SuccessGreen,
            modifier = Modifier.size(18.dp),
        )
        Spacer(Modifier.width(10.dp))
        Text(text, color = PrimaryText, fontSize = 15.sp)
    }
}

// ══════════════════════════════════════════════════════════════════
// Reusable wizard components
// ══════════════════════════════════════════════════════════════════

@Composable
private fun WizardCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(WizardBgCard)
            .border(1.dp, WizardBorderSubtle, RoundedCornerShape(16.dp))
            .padding(24.dp),
        content = content,
    )
}

@Composable
private fun WizardOptionCard(
    title: String,
    subtitle: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(if (selected) WizardBgElevated else WizardBgCard)
            .border(
                width = if (selected) 2.dp else 1.dp,
                color = if (selected) WizardBorderActive else WizardBorderSubtle,
                shape = RoundedCornerShape(12.dp),
            )
            .clickable(onClick = onClick)
            .padding(16.dp),
    ) {
        Text(
            text = title,
            color = if (selected) WizardAccent else PrimaryText,
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            text = subtitle,
            color = SecondaryText,
            fontSize = 12.sp,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun WizardPrimaryButton(
    text: String,
    enabled: Boolean = true,
    isLoading: Boolean = false,
    onClick: () -> Unit,
) {
    Button(
        onClick = onClick,
        enabled = enabled && !isLoading,
        shape = RoundedCornerShape(12.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = Color.Transparent,
            disabledContainerColor = Color.Transparent,
        ),
        contentPadding = PaddingValues(),
        modifier = Modifier
            .fillMaxWidth()
            .height(52.dp),
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .fillMaxSize()
                .background(
                    brush = if (enabled) WizardGradient
                    else Brush.horizontalGradient(
                        listOf(Color(0xFF52525B), Color(0xFF52525B)),
                    ),
                    shape = RoundedCornerShape(12.dp),
                ),
        ) {
            if (isLoading) {
                CircularProgressIndicator(
                    color = Color.White,
                    strokeWidth = 2.dp,
                    modifier = Modifier.size(22.dp),
                )
            } else {
                Text(
                    text = text,
                    color = Color.White,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}

@Composable
private fun WizardSecondaryButton(
    text: String,
    onClick: () -> Unit,
) {
    TextButton(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            text = text,
            color = SecondaryText,
            fontSize = 15.sp,
        )
    }
}

@Composable
private fun WizardTabRow(
    tabs: List<String>,
    selectedTab: Int,
    onTabSelected: (Int) -> Unit,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        for ((index, tab) in tabs.withIndex()) {
            val isSelected = index == selectedTab
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(8.dp))
                    .background(if (isSelected) WizardBgElevated else Color.Transparent)
                    .border(
                        width = 1.dp,
                        color = if (isSelected) WizardBorderActive else WizardBorderSubtle,
                        shape = RoundedCornerShape(8.dp),
                    )
                    .clickable { onTabSelected(index) }
                    .padding(vertical = 10.dp),
            ) {
                Text(
                    text = tab,
                    color = if (isSelected) WizardAccent else SecondaryText,
                    fontSize = 14.sp,
                    fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                )
            }
        }
    }
}

@Composable
private fun wizardTextFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedBorderColor = WizardAccent,
    unfocusedBorderColor = WizardBorderSubtle,
    cursorColor = WizardAccent,
    focusedLabelColor = WizardAccent,
)
