package com.nostrvault.ui.screens

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.service.GroupService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Create a new NIP-29 group.
 */

@HiltViewModel
class GroupCreateViewModel @Inject constructor(
    private val groupService: GroupService,
) : ViewModel() {

    private val _name = MutableStateFlow("")
    val name = _name.asStateFlow()

    private val _about = MutableStateFlow("")
    val about = _about.asStateFlow()

    private val _relayUrl = MutableStateFlow("")
    val relayUrl = _relayUrl.asStateFlow()

    private val _isPrivate = MutableStateFlow(false)
    val isPrivate = _isPrivate.asStateFlow()

    private val _isClosed = MutableStateFlow(false)
    val isClosed = _isClosed.asStateFlow()

    private val _isCreating = MutableStateFlow(false)
    val isCreating = _isCreating.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()

    val savedRelays: List<String> = groupService.knownGroupRelays()

    fun setName(v: String) { _name.value = v }
    fun setAbout(v: String) { _about.value = v }
    fun setRelayUrl(v: String) { _relayUrl.value = v }
    fun setPrivate(v: Boolean) { _isPrivate.value = v }
    fun setClosed(v: Boolean) { _isClosed.value = v }

    fun create(onCreated: () -> Unit) {
        val name = _name.value.trim()
        val relay = _relayUrl.value.trim()
        if (name.isBlank()) {
            _error.value = "Group name is required"
            return
        }
        if (!relay.startsWith("wss://")) {
            _error.value = "Valid relay URL required (wss://...)"
            return
        }

        viewModelScope.launch {
            _isCreating.value = true
            _error.value = null
            try {
                groupService.createGroup(
                    relayURL = relay,
                    name = name,
                    about = _about.value.trim(),
                    isPrivate = _isPrivate.value,
                    isClosed = _isClosed.value,
                )
                onCreated()
            } catch (e: Exception) {
                _error.value = e.message ?: "Failed to create group"
            }
            _isCreating.value = false
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GroupCreateScreen(
    onCreated: () -> Unit,
    onBack: () -> Unit,
    viewModel: GroupCreateViewModel = hiltViewModel(),
) {
    val name by viewModel.name.collectAsState()
    val about by viewModel.about.collectAsState()
    val relayUrl by viewModel.relayUrl.collectAsState()
    val isPrivate by viewModel.isPrivate.collectAsState()
    val isClosed by viewModel.isClosed.collectAsState()
    val isCreating by viewModel.isCreating.collectAsState()
    val error by viewModel.error.collectAsState()
    val colors = LocalNostrVaultColors.current

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Create Group") },
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
            error?.let {
                Surface(
                    color = ErrorRed.copy(alpha = 0.1f),
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(it, color = ErrorRed, modifier = Modifier.padding(12.dp))
                }
                Spacer(Modifier.height(12.dp))
            }

            OutlinedTextField(
                value = name,
                onValueChange = viewModel::setName,
                label = { Text("Group Name") },
                singleLine = true,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = colors.primary,
                    unfocusedBorderColor = SeparatorColor,
                    cursorColor = colors.primary,
                    focusedLabelColor = colors.primary,
                ),
                shape = RoundedCornerShape(8.dp),
                modifier = Modifier.fillMaxWidth(),
            )

            Spacer(Modifier.height(12.dp))

            OutlinedTextField(
                value = about,
                onValueChange = viewModel::setAbout,
                label = { Text("Description (optional)") },
                minLines = 3,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = colors.primary,
                    unfocusedBorderColor = SeparatorColor,
                    cursorColor = colors.primary,
                    focusedLabelColor = colors.primary,
                ),
                shape = RoundedCornerShape(8.dp),
                modifier = Modifier.fillMaxWidth(),
            )

            Spacer(Modifier.height(12.dp))

            OutlinedTextField(
                value = relayUrl,
                onValueChange = viewModel::setRelayUrl,
                label = { Text("Relay URL") },
                placeholder = { Text("wss://groups.relay.example.com") },
                singleLine = true,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = colors.primary,
                    unfocusedBorderColor = SeparatorColor,
                    cursorColor = colors.primary,
                    focusedLabelColor = colors.primary,
                ),
                shape = RoundedCornerShape(8.dp),
                modifier = Modifier.fillMaxWidth(),
            )

            // Saved relay quick-pick chips
            if (viewModel.savedRelays.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState()),
                ) {
                    viewModel.savedRelays.forEach { url ->
                        AssistChip(
                            onClick = { viewModel.setRelayUrl(url) },
                            label = { Text(url.removePrefix("wss://"), fontSize = 12.sp) },
                        )
                    }
                }
            }

            Spacer(Modifier.height(16.dp))

            // Privacy toggles
            GroupToggleRow(
                title = "Private",
                subtitle = "Only members can read messages",
                checked = isPrivate,
                onCheckedChange = viewModel::setPrivate,
                accent = colors.primary,
            )
            Spacer(Modifier.height(8.dp))
            GroupToggleRow(
                title = "Closed",
                subtitle = "New members need approval to join",
                checked = isClosed,
                onCheckedChange = viewModel::setClosed,
                accent = colors.primary,
            )

            Spacer(Modifier.height(24.dp))

            Button(
                onClick = { viewModel.create(onCreated) },
                enabled = name.isNotBlank() && relayUrl.isNotBlank() && !isCreating,
                colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .height(48.dp),
            ) {
                if (isCreating) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(20.dp),
                        strokeWidth = 2.dp,
                        color = PrimaryText,
                    )
                } else {
                    Text("Create Group", fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

@Composable
private fun GroupToggleRow(
    title: String,
    subtitle: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    accent: androidx.compose.ui.graphics.Color,
) {
    Row(
        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(title, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.Medium)
            Text(subtitle, color = SecondaryText, fontSize = 12.sp)
        }
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            colors = SwitchDefaults.colors(checkedThumbColor = PrimaryText, checkedTrackColor = accent),
        )
    }
}
