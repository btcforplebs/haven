package com.nostrvault.ui.screens.profile

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
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Profile editing screen for name, display_name, about, nip05, lud16, picture, website.
 */
@HiltViewModel
class ProfileEditViewModel @Inject constructor(
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
) : ViewModel() {

    private val _displayName = MutableStateFlow("")
    val displayName = _displayName.asStateFlow()

    private val _name = MutableStateFlow("")
    val name = _name.asStateFlow()

    private val _about = MutableStateFlow("")
    val about = _about.asStateFlow()

    private val _pictureUrl = MutableStateFlow("")
    val pictureUrl = _pictureUrl.asStateFlow()

    private val _nip05 = MutableStateFlow("")
    val nip05 = _nip05.asStateFlow()

    private val _lud16 = MutableStateFlow("")
    val lud16 = _lud16.asStateFlow()

    private val _website = MutableStateFlow("")
    val website = _website.asStateFlow()

    private val _isSaving = MutableStateFlow(false)
    val isSaving = _isSaving.asStateFlow()

    init {
        val pubkey = configStore.activeAccountHexPubkey.value
        val profile = nostrService.profiles.value[pubkey]
        profile?.let {
            _displayName.value = it.displayName ?: ""
            _name.value = it.name ?: ""
            _about.value = it.about ?: ""
            _pictureUrl.value = it.pictureURL ?: ""
            _nip05.value = it.nip05 ?: ""
            _lud16.value = it.lud16 ?: ""
            _website.value = it.website ?: ""
        }
    }

    fun setDisplayName(v: String) { _displayName.value = v }
    fun setName(v: String) { _name.value = v }
    fun setAbout(v: String) { _about.value = v }
    fun setPictureUrl(v: String) { _pictureUrl.value = v }
    fun setNip05(v: String) { _nip05.value = v }
    fun setLud16(v: String) { _lud16.value = v }
    fun setWebsite(v: String) { _website.value = v }

    fun save(onSaved: () -> Unit) {
        viewModelScope.launch {
            _isSaving.value = true
            val metadataJson = buildString {
                append("{")
                val fields = mutableListOf<String>()
                if (_displayName.value.isNotBlank()) fields.add("\"display_name\":\"${_displayName.value.replace("\"", "\\\"")}\"")
                if (_name.value.isNotBlank()) fields.add("\"name\":\"${_name.value.replace("\"", "\\\"")}\"")
                if (_about.value.isNotBlank()) fields.add("\"about\":\"${_about.value.replace("\"", "\\\"").replace("\n", "\\n")}\"")
                if (_pictureUrl.value.isNotBlank()) fields.add("\"picture\":\"${_pictureUrl.value}\"")
                if (_nip05.value.isNotBlank()) fields.add("\"nip05\":\"${_nip05.value}\"")
                if (_lud16.value.isNotBlank()) fields.add("\"lud16\":\"${_lud16.value}\"")
                if (_website.value.isNotBlank()) fields.add("\"website\":\"${_website.value}\"")
                append(fields.joinToString(","))
                append("}")
            }
            val event = nostrService.signEventAsync(kind = 0, content = metadataJson, tags = emptyList())
            event?.let { nostrService.postEvent(it) }
            _isSaving.value = false
            onSaved()
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProfileEditScreen(
    onSaved: () -> Unit,
    onBack: () -> Unit,
    viewModel: ProfileEditViewModel = hiltViewModel(),
) {
    val displayName by viewModel.displayName.collectAsState()
    val name by viewModel.name.collectAsState()
    val about by viewModel.about.collectAsState()
    val pictureUrl by viewModel.pictureUrl.collectAsState()
    val nip05 by viewModel.nip05.collectAsState()
    val lud16 by viewModel.lud16.collectAsState()
    val website by viewModel.website.collectAsState()
    val isSaving by viewModel.isSaving.collectAsState()
    val colors = LocalNostrVaultColors.current

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Edit Profile") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back")
                    }
                },
                actions = {
                    TextButton(
                        onClick = { viewModel.save(onSaved) },
                        enabled = !isSaving,
                    ) {
                        if (isSaving) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(16.dp),
                                strokeWidth = 2.dp,
                            )
                        } else {
                            Text("Save", color = colors.primary, fontWeight = FontWeight.SemiBold)
                        }
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
            ProfileField("Display Name", displayName, viewModel::setDisplayName)
            ProfileField("Username", name, viewModel::setName)
            ProfileField("About", about, viewModel::setAbout, singleLine = false, minLines = 3)
            ProfileField("Profile Picture URL", pictureUrl, viewModel::setPictureUrl)
            ProfileField("NIP-05 Identifier", nip05, viewModel::setNip05)
            ProfileField("Lightning Address", lud16, viewModel::setLud16)
            ProfileField("Website", website, viewModel::setWebsite)
            Spacer(Modifier.height(32.dp))
        }
    }
}

@Composable
private fun ProfileField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    singleLine: Boolean = true,
    minLines: Int = 1,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = singleLine,
        minLines = minLines,
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = LocalNostrVaultColors.current.primary,
            unfocusedBorderColor = SeparatorColor,
            cursorColor = LocalNostrVaultColors.current.primary,
            focusedLabelColor = LocalNostrVaultColors.current.primary,
        ),
        shape = RoundedCornerShape(8.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 12.dp),
    )
}
