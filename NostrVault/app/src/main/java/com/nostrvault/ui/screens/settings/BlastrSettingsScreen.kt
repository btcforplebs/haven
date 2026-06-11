package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Blastr relay editor for broadcast relay configuration.
 * Matches iOS BlastrSettingsView.
 */
@HiltViewModel
class BlastrSettingsViewModel @Inject constructor(
    private val configStore: ConfigStore,
) : ViewModel() {

    private val _relays = MutableStateFlow<List<String>>(emptyList())
    val relays = _relays.asStateFlow()

    private val _newRelayUrl = MutableStateFlow("")
    val newRelayUrl = _newRelayUrl.asStateFlow()

    init {
        _relays.value = configStore.config.value.blastrRelays
    }

    fun setNewRelayUrl(url: String) { _newRelayUrl.value = url }

    fun addRelay() {
        val url = _newRelayUrl.value.trim().let {
            if (!it.startsWith("wss://") && !it.startsWith("ws://")) "wss://$it" else it
        }
        if (url.isBlank()) return
        if (url in _relays.value) return

        _relays.value = _relays.value + url
        _newRelayUrl.value = ""
        save()
    }

    fun removeRelay(url: String) {
        _relays.value = _relays.value - url
        save()
    }

    private fun save() {
        viewModelScope.launch {
            configStore.update { it.copy(blastrRelays = _relays.value) }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BlastrSettingsScreen(
    onBack: () -> Unit,
    viewModel: BlastrSettingsViewModel = hiltViewModel(),
) {
    val relays by viewModel.relays.collectAsState()
    val newRelayUrl by viewModel.newRelayUrl.collectAsState()
    val colors = LocalNostrVaultColors.current

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Blastr Broadcasting") },
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
                .padding(padding),
        ) {
            // Info banner
            Surface(
                color = colors.primary.copy(alpha = 0.1f),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
            ) {
                Row(
                    modifier = Modifier.padding(12.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    Icon(
                        NostrVaultIcons.Info,
                        contentDescription = null,
                        tint = colors.primary,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = "Notes you publish are broadcast to these relays so they are widely available on the network.",
                        color = SecondaryText,
                        fontSize = 12.sp,
                    )
                }
            }

            // Add relay input
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp),
            ) {
                OutlinedTextField(
                    value = newRelayUrl,
                    onValueChange = viewModel::setNewRelayUrl,
                    placeholder = { Text("wss://relay.example.com") },
                    singleLine = true,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = colors.primary,
                        unfocusedBorderColor = SeparatorColor,
                        cursorColor = colors.primary,
                    ),
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.width(8.dp))
                IconButton(
                    onClick = viewModel::addRelay,
                    enabled = newRelayUrl.isNotBlank(),
                ) {
                    Icon(
                        imageVector = NostrVaultIcons.Create,
                        contentDescription = "Add",
                        tint = if (newRelayUrl.isNotBlank()) colors.primary else TertiaryText,
                    )
                }
            }

            HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)

            if (relays.isEmpty()) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(32.dp),
                ) {
                    Text("No blastr relays configured", color = SecondaryText, fontSize = 15.sp)
                }
            } else {
                LazyColumn(modifier = Modifier.fillMaxSize()) {
                    items(relays) { relay ->
                        BlastrRelayRow(
                            url = relay,
                            onRemove = { viewModel.removeRelay(relay) },
                        )
                        HorizontalDivider(
                            color = SeparatorColor,
                            thickness = 0.5.dp,
                            modifier = Modifier.padding(start = 16.dp),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun BlastrRelayRow(
    url: String,
    onRemove: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Icon(
            imageVector = NostrVaultIcons.Blastr,
            contentDescription = null,
            tint = LocalNostrVaultColors.current.primary,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(12.dp))
        Text(
            text = url.removePrefix("wss://"),
            color = PrimaryText,
            fontSize = 15.sp,
            modifier = Modifier.weight(1f),
        )
        IconButton(onClick = onRemove) {
            Icon(
                imageVector = NostrVaultIcons.Delete,
                contentDescription = "Remove",
                tint = ErrorRed,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}
