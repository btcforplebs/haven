package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.ui.graphics.Color
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.relay.HavenBridge
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Account management: view active account, copy keys, add accounts.
 */

@HiltViewModel
class AccountSettingsViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val credentialStore: CredentialStore,
) : ViewModel() {

    val activeHexPubkey = configStore.activeAccountHexPubkey

    private val _npub = MutableStateFlow("")
    val npub = _npub.asStateFlow()

    private val _nsecVisible = MutableStateFlow(false)
    val nsecVisible = _nsecVisible.asStateFlow()

    private val _nsec = MutableStateFlow("")
    val nsec = _nsec.asStateFlow()

    private val _signingMode = MutableStateFlow("local")
    val signingMode = _signingMode.asStateFlow()

    init {
        viewModelScope.launch {
            val hex = activeHexPubkey.value
            if (hex.isNotBlank()) {
                _npub.value = HavenBridge.hexToNpub(hex) ?: hex.take(16) + "..."
                _nsec.value = credentialStore.getNsec(hex) ?: ""
            }
            _signingMode.value = configStore.config.value.signingMode
        }
    }

    fun toggleNsecVisibility() {
        _nsecVisible.value = !_nsecVisible.value
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountSettingsScreen(
    onBack: () -> Unit,
    viewModel: AccountSettingsViewModel = hiltViewModel(),
) {
    val npub by viewModel.npub.collectAsState()
    val nsec by viewModel.nsec.collectAsState()
    val nsecVisible by viewModel.nsecVisible.collectAsState()
    val signingMode by viewModel.signingMode.collectAsState()
    val clipboard = LocalClipboardManager.current
    val colors = LocalNostrVaultColors.current
    val isAmberMode = signingMode == "amber"

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Accounts") },
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
                .padding(16.dp),
        ) {
            // Signing mode badge
            Surface(
                color = SecondaryGroupedBg,
                shape = RoundedCornerShape(8.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(12.dp),
                ) {
                    Text("Signing Mode", color = SecondaryText, fontSize = 13.sp)
                    Spacer(Modifier.weight(1f))
                    Surface(
                        color = when (signingMode) {
                            "amber" -> Color(0xFF4CAF50).copy(alpha = 0.15f)
                            "nip46" -> Color(0xFF2196F3).copy(alpha = 0.15f)
                            else -> Color(0xFFF59E0B).copy(alpha = 0.15f)
                        },
                        shape = RoundedCornerShape(6.dp),
                    ) {
                        Text(
                            text = when (signingMode) {
                                "amber" -> "Amber (NIP-55)"
                                "nip46" -> "Remote (NIP-46)"
                                else -> "Local Key"
                            },
                            color = when (signingMode) {
                                "amber" -> Color(0xFF4CAF50)
                                "nip46" -> Color(0xFF2196F3)
                                else -> Color(0xFFF59E0B)
                            },
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                        )
                    }
                }
            }

            Spacer(Modifier.height(16.dp))

            // Active account card
            Surface(
                color = SecondaryGroupedBg,
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text(
                        text = "Active Account",
                        color = SecondaryText,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Spacer(Modifier.height(12.dp))

                    // npub
                    KeyRow(
                        label = "Public Key (npub)",
                        value = npub,
                        onCopy = { clipboard.setText(AnnotatedString(npub)) },
                    )

                    // nsec (hidden when using Amber -- no private key on device)
                    if (!isAmberMode && nsec.isNotBlank()) {
                        Spacer(Modifier.height(12.dp))

                        KeyRow(
                            label = "Private Key (nsec)",
                            value = if (nsecVisible) nsec else "nsec1" + "*".repeat(50),
                            onCopy = { clipboard.setText(AnnotatedString(nsec)) },
                            onToggleVisibility = viewModel::toggleNsecVisibility,
                            isSecret = true,
                        )
                    }
                }
            }

            Spacer(Modifier.height(24.dp))

            // Warning
            Surface(
                color = WarningYellow.copy(alpha = 0.1f),
                shape = RoundedCornerShape(8.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Row(
                    modifier = Modifier.padding(12.dp),
                ) {
                    Icon(
                        imageVector = NostrVaultIcons.Alert,
                        contentDescription = null,
                        tint = WarningYellow,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = if (isAmberMode)
                            "Your private key is managed by Amber. Nostr Vault never sees or stores it."
                        else
                            "Never share your private key (nsec). Anyone with your nsec has full control of your Nostr identity.",
                        color = WarningYellow,
                        fontSize = 13.sp,
                        lineHeight = 18.sp,
                    )
                }
            }
        }
    }
}

@Composable
private fun KeyRow(
    label: String,
    value: String,
    onCopy: () -> Unit,
    onToggleVisibility: (() -> Unit)? = null,
    isSecret: Boolean = false,
) {
    Column {
        Text(
            text = label,
            color = TertiaryText,
            fontSize = 11.sp,
        )
        Spacer(Modifier.height(4.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = value.take(32) + if (value.length > 32) "..." else "",
                color = PrimaryText,
                fontSize = 13.sp,
                fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                modifier = Modifier.weight(1f),
            )
            if (onToggleVisibility != null) {
                IconButton(onClick = onToggleVisibility, modifier = Modifier.size(28.dp)) {
                    Icon(
                        imageVector = NostrVaultIcons.Accounts,
                        contentDescription = "Toggle visibility",
                        tint = SecondaryText,
                        modifier = Modifier.size(16.dp),
                    )
                }
            }
            IconButton(onClick = onCopy, modifier = Modifier.size(28.dp)) {
                Icon(
                    imageVector = NostrVaultIcons.Copy,
                    contentDescription = "Copy",
                    tint = SecondaryText,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
    }
}
