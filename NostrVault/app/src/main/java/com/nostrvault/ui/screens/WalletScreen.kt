package com.nostrvault.ui.screens

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.zxing.BarcodeFormat
import com.journeyapps.barcodescanner.BarcodeEncoder
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.HavenConfig
import com.nostrvault.service.CashuService
import com.nostrvault.service.NWCService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Wallet configuration screen — port of iOS WalletSettingsView.
 * NWC (Nostr Wallet Connect) + default zap, Cashu ecash, and a Bitcoin
 * taproot (BIP-341) address derived from the Nostr keypair.
 */
@HiltViewModel
class WalletViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val nwcService: NWCService,
    private val cashuService: CashuService,
    private val nostrService: NostrService,
) : ViewModel() {
    val config: StateFlow<HavenConfig> = configStore.config
    val cashuBalance: StateFlow<ULong> = cashuService.balanceSats

    private val _lightningBalance = MutableStateFlow<Long?>(null)
    val lightningBalance = _lightningBalance.asStateFlow()

    private val _taprootAddress = MutableStateFlow<String?>(null)
    val taprootAddress = _taprootAddress.asStateFlow()

    init {
        refreshBalance()
        if (config.value.showBitcoinWallet) deriveAddress()
    }

    fun setNwcUri(uri: String) = configStore.update { it.copy(nwcURI = uri.ifBlank { null }) }
    fun setDefaultZap(sats: Int) = configStore.update { it.copy(defaultZapAmount = sats.coerceAtLeast(1)) }
    fun setCashuMint(url: String) = configStore.update { it.copy(cashuMintURL = url) }

    fun toggleBitcoin(on: Boolean) {
        configStore.update { it.copy(showBitcoinWallet = on) }
        if (on) deriveAddress() else _taprootAddress.value = null
    }

    fun refreshBalance() {
        viewModelScope.launch {
            _lightningBalance.value = try {
                nwcService.getBalance()
            } catch (_: Exception) {
                null
            }
        }
    }

    private fun deriveAddress() {
        val hex = nostrService.ownerHexPubkey
        if (hex.isNotEmpty()) _taprootAddress.value = HavenBridge.deriveTaprootAddress(hex)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WalletScreen(
    onBack: () -> Unit,
    onSweep: () -> Unit = {},
    viewModel: WalletViewModel = hiltViewModel(),
) {
    val config by viewModel.config.collectAsState()
    val lightningBalance by viewModel.lightningBalance.collectAsState()
    val cashuBalance by viewModel.cashuBalance.collectAsState()
    val taproot by viewModel.taprootAddress.collectAsState()
    val colors = LocalNostrVaultColors.current
    val clipboard = LocalClipboardManager.current

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Wallet", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = WindowBackground,
                    titleContentColor = PrimaryText,
                    navigationIconContentColor = PrimaryText,
                ),
            )
        },
        containerColor = WindowBackground,
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            // ── Nostr Wallet Connect ──────────────────────────────
            SectionLabel("Nostr Wallet Connect (NWC)")
            OutlinedTextField(
                value = config.nwcURI ?: "",
                onValueChange = viewModel::setNwcUri,
                placeholder = { Text("nostr+walletconnect://…") },
                modifier = Modifier.fillMaxWidth(),
                minLines = 2,
                colors = walletFieldColors(colors.primary),
            )
            Caption("Connect a Lightning wallet to send zaps.")

            if (!config.nwcURI.isNullOrBlank()) {
                Spacer(Modifier.height(12.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = "Balance: " + (lightningBalance?.let { "$it sats" } ?: "Unknown"),
                        color = PrimaryText, fontSize = 15.sp, modifier = Modifier.weight(1f),
                    )
                    TextButton(onClick = viewModel::refreshBalance) { Text("Refresh", color = colors.primary) }
                }
                Spacer(Modifier.height(8.dp))
                var zapText by remember(config.defaultZapAmount) { mutableStateOf(config.defaultZapAmount.toString()) }
                OutlinedTextField(
                    value = zapText,
                    onValueChange = { t -> zapText = t.filter { it.isDigit() }; zapText.toIntOrNull()?.let(viewModel::setDefaultZap) },
                    label = { Text("Default Zap Amount (sats)") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth(),
                    colors = walletFieldColors(colors.primary),
                )
            }

            Spacer(Modifier.height(24.dp))

            // ── Cashu ─────────────────────────────────────────────
            SectionLabel("Cashu Mint")
            OutlinedTextField(
                value = config.cashuMintURL,
                onValueChange = viewModel::setCashuMint,
                placeholder = { Text("https://mint.example.com") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                colors = walletFieldColors(colors.primary),
            )
            if (config.cashuMintURL.isNotBlank()) {
                Spacer(Modifier.height(8.dp))
                Text("Ecash Balance: $cashuBalance sats", color = PrimaryText, fontSize = 15.sp)
            }

            Spacer(Modifier.height(24.dp))

            // ── Bitcoin ───────────────────────────────────────────
            SectionLabel("Bitcoin")
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("Bitcoin Address", color = PrimaryText, fontSize = 15.sp)
                    Text("Derive a taproot address from your Nostr key (BIP-341)", color = SecondaryText, fontSize = 12.sp)
                }
                Switch(
                    checked = config.showBitcoinWallet,
                    onCheckedChange = viewModel::toggleBitcoin,
                    colors = SwitchDefaults.colors(checkedThumbColor = PrimaryText, checkedTrackColor = colors.primary),
                )
            }

            if (config.showBitcoinWallet && taproot != null) {
                Spacer(Modifier.height(12.dp))
                QrCode(taproot!!)
                Spacer(Modifier.height(8.dp))
                Text(
                    text = taproot!!,
                    color = PrimaryText,
                    fontSize = 12.sp,
                    fontFamily = FontFamily.Monospace,
                )
                Spacer(Modifier.height(8.dp))
                Row {
                    OutlinedButton(onClick = { clipboard.setText(AnnotatedString(taproot!!)) }) {
                        Text("Copy Address")
                    }
                    Spacer(Modifier.width(8.dp))
                    Button(
                        onClick = onSweep,
                        colors = ButtonDefaults.buttonColors(containerColor = ZapOrange),
                    ) { Text("Sweep Wallet") }
                }
            }

            Spacer(Modifier.height(32.dp))
        }
    }
}

@Composable
private fun QrCode(content: String) {
    val bitmap = remember(content) {
        runCatching {
            BarcodeEncoder().encodeBitmap(content, BarcodeFormat.QR_CODE, 480, 480)
        }.getOrNull()
    }
    if (bitmap != null) {
        Image(
            bitmap = bitmap.asImageBitmap(),
            contentDescription = "Bitcoin address QR",
            modifier = Modifier.size(200.dp),
        )
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text = text.uppercase(),
        color = SecondaryText,
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 1.sp,
        modifier = Modifier.padding(bottom = 8.dp),
    )
}

@Composable
private fun Caption(text: String) {
    Text(text = text, color = SecondaryText, fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp))
}

@Composable
private fun walletFieldColors(primary: androidx.compose.ui.graphics.Color) = OutlinedTextFieldDefaults.colors(
    focusedTextColor = PrimaryText,
    unfocusedTextColor = PrimaryText,
    cursorColor = primary,
    focusedBorderColor = primary,
)
