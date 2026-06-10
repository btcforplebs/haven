package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.service.CashuService
import com.nostrvault.service.NWCService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Wallet screen showing NWC balance and Cashu token management.
 * Port of WalletView.swift.
 */

@HiltViewModel
class WalletViewModel @Inject constructor(
    private val nwcService: NWCService,
    private val cashuService: CashuService,
) : ViewModel() {

    private val _balanceSats = MutableStateFlow(0L)
    val balanceSats = _balanceSats.asStateFlow()

    private val _cashuBalance = MutableStateFlow(0L)
    val cashuBalance = _cashuBalance.asStateFlow()

    private val _isNwcConnected = MutableStateFlow(false)
    val isNwcConnected = _isNwcConnected.asStateFlow()

    private val _isLoading = MutableStateFlow(true)
    val isLoading = _isLoading.asStateFlow()

    init {
        loadBalances()
    }

    fun loadBalances() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                _balanceSats.value = nwcService.getBalance()
                _isNwcConnected.value = true
            } catch (_: Exception) {
                _isNwcConnected.value = false
            }
            _cashuBalance.value = cashuService.balanceSats.value.toLong()
            _isLoading.value = false
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WalletScreen(
    onBack: () -> Unit,
    viewModel: WalletViewModel = hiltViewModel(),
) {
    val balanceSats by viewModel.balanceSats.collectAsState()
    val cashuBalance by viewModel.cashuBalance.collectAsState()
    val isNwcConnected by viewModel.isNwcConnected.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val colors = LocalNostrVaultColors.current

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
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            if (isLoading) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier.padding(32.dp),
                ) {
                    CircularProgressIndicator(color = colors.primary)
                }
            } else {
                // NWC Balance
                Surface(
                    color = SecondaryGroupedBg,
                    shape = RoundedCornerShape(16.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.padding(24.dp),
                    ) {
                        Text("Lightning Balance", color = SecondaryText, fontSize = 14.sp)
                        Spacer(Modifier.height(8.dp))
                        Row(verticalAlignment = Alignment.Bottom) {
                            Icon(
                                imageVector = NostrVaultIcons.Zap,
                                contentDescription = null,
                                tint = ZapOrange,
                                modifier = Modifier.size(28.dp),
                            )
                            Spacer(Modifier.width(8.dp))
                            Text(
                                text = formatSats(balanceSats),
                                color = PrimaryText,
                                fontSize = 36.sp,
                                fontWeight = FontWeight.Bold,
                            )
                            Spacer(Modifier.width(4.dp))
                            Text("sats", color = SecondaryText, fontSize = 16.sp)
                        }
                        if (!isNwcConnected) {
                            Spacer(Modifier.height(8.dp))
                            Text(
                                text = "NWC not connected",
                                color = WarningYellow,
                                fontSize = 13.sp,
                            )
                        }
                    }
                }

                Spacer(Modifier.height(16.dp))

                // Cashu Balance
                Surface(
                    color = SecondaryGroupedBg,
                    shape = RoundedCornerShape(16.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.padding(24.dp),
                    ) {
                        Text("Cashu Balance", color = SecondaryText, fontSize = 14.sp)
                        Spacer(Modifier.height(8.dp))
                        Text(
                            text = "${formatSats(cashuBalance)} sats",
                            color = PrimaryText,
                            fontSize = 24.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                    }
                }

                Spacer(Modifier.height(24.dp))

                // Action buttons
                Row(
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    OutlinedButton(
                        onClick = { /* TODO: Receive */ },
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.weight(1f),
                    ) {
                        Text("Receive")
                    }
                    Button(
                        onClick = { /* TODO: Send */ },
                        colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.weight(1f),
                    ) {
                        Text("Send")
                    }
                }
            }
        }
    }
}

private fun formatSats(sats: Long): String {
    return when {
        sats >= 1_000_000 -> "%.1fM".format(sats / 1_000_000.0)
        sats >= 1_000 -> "%,d".format(sats)
        else -> sats.toString()
    }
}
