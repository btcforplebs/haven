package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenBridge
import com.nostrvault.ui.notification.NotificationManager
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject

/**
 * Cloud backup settings (S3-compatible provider).
 * Calls HavenBridge.backupToCloud() and restoreFromCloud() via JNI.
 */

@HiltViewModel
class CloudBackupViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val notificationManager: NotificationManager,
) : ViewModel() {

    private val _provider = MutableStateFlow("")
    val provider = _provider.asStateFlow()

    private val _endpoint = MutableStateFlow("")
    val endpoint = _endpoint.asStateFlow()

    private val _region = MutableStateFlow("")
    val region = _region.asStateFlow()

    private val _bucket = MutableStateFlow("")
    val bucket = _bucket.asStateFlow()

    private val _accessKey = MutableStateFlow("")
    val accessKey = _accessKey.asStateFlow()

    private val _secretKey = MutableStateFlow("")
    val secretKey = _secretKey.asStateFlow()

    private val _intervalHours = MutableStateFlow(24)
    val intervalHours = _intervalHours.asStateFlow()

    private val _isOperating = MutableStateFlow(false)
    val isOperating = _isOperating.asStateFlow()

    init {
        val config = configStore.config.value
        _provider.value = config.backupProvider
        _endpoint.value = config.s3Endpoint
        _region.value = config.s3Region
        _bucket.value = config.s3BucketName
        _accessKey.value = config.s3AccessKeyId
        _secretKey.value = config.s3SecretKey
        _intervalHours.value = config.backupIntervalHours
    }

    fun setProvider(v: String) { _provider.value = v }
    fun setEndpoint(v: String) { _endpoint.value = v }
    fun setRegion(v: String) { _region.value = v }
    fun setBucket(v: String) { _bucket.value = v }
    fun setAccessKey(v: String) { _accessKey.value = v }
    fun setSecretKey(v: String) { _secretKey.value = v }
    fun setIntervalHours(v: Int) { _intervalHours.value = v }

    fun saveConfig() {
        viewModelScope.launch {
            configStore.update {
                it.copy(
                    backupProvider = _provider.value,
                    s3Endpoint = _endpoint.value,
                    s3Region = _region.value,
                    s3BucketName = _bucket.value,
                    s3AccessKeyId = _accessKey.value,
                    s3SecretKey = _secretKey.value,
                    backupIntervalHours = _intervalHours.value,
                )
            }
            notificationManager.showToast("Backup settings saved")
        }
    }

    fun backupNow() {
        if (_isOperating.value) return
        viewModelScope.launch {
            _isOperating.value = true
            try {
                val result = withContext(Dispatchers.IO) {
                    HavenBridge.backupToCloud()
                }
                if (result == 0) {
                    notificationManager.showToast("Cloud backup completed")
                } else {
                    notificationManager.showError("Cloud backup failed")
                }
            } catch (e: Exception) {
                notificationManager.showError("Backup error: ${e.message}")
            }
            _isOperating.value = false
        }
    }

    fun restoreNow() {
        if (_isOperating.value) return
        viewModelScope.launch {
            _isOperating.value = true
            try {
                val result = withContext(Dispatchers.IO) {
                    HavenBridge.restoreFromCloud()
                }
                if (result == 0) {
                    notificationManager.showToast("Cloud restore completed")
                } else {
                    notificationManager.showError("Cloud restore failed")
                }
            } catch (e: Exception) {
                notificationManager.showError("Restore error: ${e.message}")
            }
            _isOperating.value = false
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CloudBackupScreen(
    onBack: () -> Unit,
    viewModel: CloudBackupViewModel = hiltViewModel(),
) {
    val provider by viewModel.provider.collectAsState()
    val endpoint by viewModel.endpoint.collectAsState()
    val region by viewModel.region.collectAsState()
    val bucket by viewModel.bucket.collectAsState()
    val accessKey by viewModel.accessKey.collectAsState()
    val secretKey by viewModel.secretKey.collectAsState()
    val intervalHours by viewModel.intervalHours.collectAsState()
    val isOperating by viewModel.isOperating.collectAsState()
    val colors = LocalNostrVaultColors.current

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Cloud Backup") },
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
            Text(
                text = "S3-Compatible Storage",
                color = PrimaryText,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "Configure an S3-compatible endpoint for automated relay backups.",
                color = SecondaryText,
                fontSize = 13.sp,
            )

            Spacer(Modifier.height(16.dp))

            BackupTextField("Provider", provider, viewModel::setProvider)
            BackupTextField("Endpoint URL", endpoint, viewModel::setEndpoint)
            BackupTextField("Region", region, viewModel::setRegion)
            BackupTextField("Bucket Name", bucket, viewModel::setBucket)
            BackupTextField("Access Key ID", accessKey, viewModel::setAccessKey)
            BackupTextField("Secret Key", secretKey, viewModel::setSecretKey, isSecret = true)

            Spacer(Modifier.height(16.dp))

            Text(
                text = "Backup Interval",
                color = PrimaryText,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
            )
            Spacer(Modifier.height(4.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Slider(
                    value = intervalHours.toFloat(),
                    onValueChange = { viewModel.setIntervalHours(it.toInt()) },
                    valueRange = 1f..168f,
                    colors = SliderDefaults.colors(
                        thumbColor = colors.primary,
                        activeTrackColor = colors.primary,
                    ),
                    modifier = Modifier.weight(1f),
                )
                Text(
                    text = "${intervalHours}h",
                    color = SecondaryText,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(start = 8.dp),
                )
            }

            Spacer(Modifier.height(16.dp))

            Button(
                onClick = { viewModel.saveConfig() },
                colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Save Configuration", color = PrimaryText)
            }

            Spacer(Modifier.height(24.dp))

            Text(
                text = "Manual Actions",
                color = PrimaryText,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.height(12.dp))

            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                OutlinedButton(
                    onClick = { viewModel.backupNow() },
                    enabled = !isOperating && provider.isNotBlank(),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.weight(1f),
                ) {
                    if (isOperating) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(16.dp),
                            strokeWidth = 2.dp,
                            color = colors.primary,
                        )
                    } else {
                        Text("Backup Now", color = colors.primary)
                    }
                }
                OutlinedButton(
                    onClick = { viewModel.restoreNow() },
                    enabled = !isOperating && provider.isNotBlank(),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.weight(1f),
                ) {
                    Text("Restore", color = colors.primary)
                }
            }
        }
    }
}

@Composable
private fun BackupTextField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    isSecret: Boolean = false,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label, color = SecondaryText) },
        singleLine = true,
        visualTransformation = if (isSecret) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = LocalNostrVaultColors.current.primary,
            unfocusedBorderColor = TertiaryText,
            cursorColor = LocalNostrVaultColors.current.primary,
            focusedTextColor = PrimaryText,
            unfocusedTextColor = PrimaryText,
        ),
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
    )
}
