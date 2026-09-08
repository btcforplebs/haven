package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.fips.FipsMeshManager
import com.nostrvault.fips.FipsStatus
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class MeshSettingsViewModel @Inject constructor(
    private val mesh: FipsMeshManager,
) : ViewModel() {

    val status = mesh.status
    val lastError = mesh.lastError
    val isAvailable = mesh.isAvailable

    private val _busy = MutableStateFlow(false)
    val busy = _busy.asStateFlow()

    init {
        viewModelScope.launch { mesh.refresh() }
    }

    fun setEnabled(enabled: Boolean) {
        if (_busy.value) return
        viewModelScope.launch {
            _busy.value = true
            if (enabled) mesh.start() else mesh.stop()
            _busy.value = false
        }
    }

    suspend fun refresh() = mesh.refresh()
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MeshSettingsScreen(
    onBack: () -> Unit,
    viewModel: MeshSettingsViewModel = hiltViewModel(),
) {
    val status by viewModel.status.collectAsState()
    val lastError by viewModel.lastError.collectAsState()
    val busy by viewModel.busy.collectAsState()
    val colors = LocalNostrVaultColors.current
    val clipboard = LocalClipboardManager.current

    // Polled, not pushed: the bridge never calls back into the JVM, so uptime
    // and state are read while this screen is on top and nowhere else.
    LaunchedEffect(status.running) {
        while (status.running) {
            delay(2000)
            viewModel.refresh()
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Mesh") },
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
                .padding(horizontal = 16.dp),
        ) {
            Spacer(Modifier.height(16.dp))

            if (!viewModel.isAvailable) {
                Notice(
                    text = "This build does not include the mesh library for your " +
                        "device's processor, so the mesh cannot be turned on here.",
                    tint = SecondaryText,
                )
                Spacer(Modifier.height(16.dp))
            }

            Text(
                text = "FIPS MESH",
                color = SecondaryText,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                letterSpacing = 1.sp,
                modifier = Modifier.padding(bottom = 8.dp),
            )

            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.weight(1f)) {
                    Text(
                        "Broadcast my address",
                        color = PrimaryText,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Medium,
                    )
                    Text(
                        "Announce this device on the mesh so peers can dial it.",
                        color = SecondaryText,
                        fontSize = 13.sp,
                        lineHeight = 18.sp,
                    )
                }
                Spacer(Modifier.width(12.dp))
                if (busy) {
                    CircularProgressIndicator(
                        strokeWidth = 2.dp,
                        color = colors.primary,
                        modifier = Modifier.size(24.dp),
                    )
                } else {
                    Switch(
                        checked = status.running,
                        onCheckedChange = viewModel::setEnabled,
                        enabled = viewModel.isAvailable,
                        colors = SwitchDefaults.colors(checkedTrackColor = colors.primary),
                    )
                }
            }

            if (status.running) {
                Spacer(Modifier.height(20.dp))
                AddressCard(
                    status = status,
                    onCopy = { clipboard.setText(AnnotatedString(it)) },
                )
            }

            lastError?.let { error ->
                Spacer(Modifier.height(16.dp))
                Notice(text = error, tint = ErrorRed)
            }

            Spacer(Modifier.height(20.dp))

            Text(
                // Said plainly on the screen because it is the difference
                // between "my address is published" and "someone can reach me",
                // and only the first of those is true today.
                text = "Your address is published to the discovery relays while this " +
                    "is on. Two devices that are both behind home or mobile NAT " +
                    "still cannot connect to each other yet — that needs a " +
                    "reachable node in the middle, which is not wired up.",
                color = SecondaryText,
                fontSize = 13.sp,
                lineHeight = 18.sp,
            )

            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun AddressCard(status: FipsStatus, onCopy: (String) -> Unit) {
    Surface(
        color = CardBackground,
        shape = RoundedCornerShape(10.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(14.dp)) {
            Text("YOUR MESH ADDRESS", color = SecondaryText, fontSize = 11.sp, letterSpacing = 1.sp)
            Spacer(Modifier.height(6.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = status.npub ?: "—",
                    color = PrimaryText,
                    fontSize = 13.sp,
                    fontFamily = FontFamily.Monospace,
                    lineHeight = 18.sp,
                    modifier = Modifier.weight(1f),
                )
                status.npub?.let { npub ->
                    IconButton(onClick = { onCopy(npub) }) {
                        Icon(
                            NostrVaultIcons.Copy,
                            contentDescription = "Copy mesh address",
                            tint = SecondaryText,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }
            }

            status.address?.let { address ->
                Spacer(Modifier.height(10.dp))
                Text("MESH IP", color = SecondaryText, fontSize = 11.sp, letterSpacing = 1.sp)
                Spacer(Modifier.height(4.dp))
                Text(
                    text = address,
                    color = SecondaryText,
                    fontSize = 12.sp,
                    fontFamily = FontFamily.Monospace,
                )
            }

            Spacer(Modifier.height(10.dp))
            Text(
                text = "Up ${formatUptime(status.uptimeSeconds)}",
                color = SuccessGreen,
                fontSize = 12.sp,
            )
        }
    }
}

@Composable
private fun Notice(text: String, tint: androidx.compose.ui.graphics.Color) {
    Surface(
        color = tint.copy(alpha = 0.1f),
        shape = RoundedCornerShape(8.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            text = text,
            color = tint,
            fontSize = 13.sp,
            lineHeight = 18.sp,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
        )
    }
}

internal fun formatUptime(seconds: Long): String = when {
    seconds < 60 -> "${seconds}s"
    seconds < 3600 -> "${seconds / 60}m ${seconds % 60}s"
    else -> "${seconds / 3600}h ${(seconds % 3600) / 60}m"
}
