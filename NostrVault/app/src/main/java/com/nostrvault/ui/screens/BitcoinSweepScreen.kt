package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import javax.inject.Inject

/**
 * Bitcoin on-chain sweep: send all funds from the Nostr-derived taproot address
 * to an external address. Port of iOS BitcoinSweepView.
 */
@HiltViewModel
class BitcoinSweepViewModel @Inject constructor(
    private val nostrService: NostrService,
) : ViewModel() {
    val fromAddress: String? = nostrService.ownerHexPubkey
        .takeIf { it.isNotEmpty() }
        ?.let { HavenBridge.deriveTaprootAddress(it) }

    private val _busy = MutableStateFlow(false)
    val busy = _busy.asStateFlow()

    private val _result = MutableStateFlow<String?>(null)
    val result = _result.asStateFlow()

    fun sweep(destAddr: String, feeRate: Int) {
        if (_busy.value) return
        viewModelScope.launch {
            _busy.value = true
            _result.value = null
            try {
                val nsecHex = nostrService.resolveOwnerSecretKey()
                if (nsecHex == null) {
                    _result.value = "No signing key available"
                    return@launch
                }
                val json = withContext(Dispatchers.IO) {
                    HavenBridge.sweepToAddress(nsecHex, destAddr.trim(), feeRate)
                }
                _result.value = parseResult(json)
            } catch (e: Exception) {
                _result.value = "Error: ${e.message}"
            } finally {
                _busy.value = false
            }
        }
    }

    private fun parseResult(json: String?): String {
        if (json == null) return "Sweep failed"
        return try {
            val obj = JSONObject(json)
            val err = obj.optString("error")
            if (err.isNotEmpty()) return "Error: $err"
            val txid = obj.optString("txid")
            if (txid.isNotEmpty()) "Broadcast: $txid" else "Sweep failed"
        } catch (_: Exception) {
            "Sweep failed"
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BitcoinSweepScreen(
    onBack: () -> Unit,
    viewModel: BitcoinSweepViewModel = hiltViewModel(),
) {
    val busy by viewModel.busy.collectAsState()
    val result by viewModel.result.collectAsState()
    val colors = LocalNostrVaultColors.current

    var dest by remember { mutableStateOf("") }
    var feeText by remember { mutableStateOf("5") }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Bitcoin Sweep") },
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
            Text("From", color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            Text(
                text = viewModel.fromAddress ?: "Unavailable",
                color = PrimaryText,
                fontSize = 12.sp,
                fontFamily = FontFamily.Monospace,
                modifier = Modifier.padding(top = 4.dp, bottom = 16.dp),
            )

            OutlinedTextField(
                value = dest,
                onValueChange = { dest = it },
                label = { Text("Destination address") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedTextColor = PrimaryText, unfocusedTextColor = PrimaryText,
                    cursorColor = colors.primary, focusedBorderColor = colors.primary,
                ),
            )
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = feeText,
                onValueChange = { t -> feeText = t.filter { it.isDigit() } },
                label = { Text("Fee rate (sats/vB)") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.fillMaxWidth(),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedTextColor = PrimaryText, unfocusedTextColor = PrimaryText,
                    cursorColor = colors.primary, focusedBorderColor = colors.primary,
                ),
            )

            Spacer(Modifier.height(16.dp))
            Button(
                onClick = { viewModel.sweep(dest, feeText.toIntOrNull() ?: 1) },
                enabled = !busy && dest.isNotBlank() && viewModel.fromAddress != null,
                colors = ButtonDefaults.buttonColors(containerColor = ZapOrange),
                modifier = Modifier.fillMaxWidth(),
            ) { Text(if (busy) "Sweeping…" else "Sweep All Funds") }

            result?.let {
                Spacer(Modifier.height(12.dp))
                Text(it, color = if (it.startsWith("Error")) ErrorRed else PrimaryText, fontSize = 13.sp)
            }
        }
    }
}
