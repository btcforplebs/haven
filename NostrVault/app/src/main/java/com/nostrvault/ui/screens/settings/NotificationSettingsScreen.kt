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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.PushNotificationService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class NotificationSettingsViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val pushService: PushNotificationService,
) : ViewModel() {

    val registrationStatus = pushService.registrationStatus

    private val _enabled = MutableStateFlow(false)
    val enabled = _enabled.asStateFlow()

    private val _serverUrl = MutableStateFlow("")
    val serverUrl = _serverUrl.asStateFlow()

    private val _mentions = MutableStateFlow(true)
    val mentions = _mentions.asStateFlow()

    private val _replies = MutableStateFlow(true)
    val replies = _replies.asStateFlow()

    private val _dms = MutableStateFlow(true)
    val dms = _dms.asStateFlow()

    private val _zaps = MutableStateFlow(true)
    val zaps = _zaps.asStateFlow()

    private val _reactions = MutableStateFlow(false)
    val reactions = _reactions.asStateFlow()

    private val _reposts = MutableStateFlow(false)
    val reposts = _reposts.asStateFlow()

    init {
        val config = configStore.config.value
        _enabled.value = config.enablePushNotifications
        _serverUrl.value = config.pushServerURL
        _mentions.value = config.pushNotifyMentions
        _replies.value = config.pushNotifyReplies
        _dms.value = config.pushNotifyDMs
        _zaps.value = config.pushNotifyZaps
        _reactions.value = config.pushNotifyReactions
        _reposts.value = config.pushNotifyReposts
    }

    fun toggleEnabled(on: Boolean) {
        _enabled.value = on
        save { it.copy(enablePushNotifications = on) }
    }

    fun setServerUrl(url: String) {
        _serverUrl.value = url
        save { it.copy(pushServerURL = url) }
    }

    fun toggleMentions(on: Boolean) {
        _mentions.value = on
        save { it.copy(pushNotifyMentions = on) }
    }

    fun toggleReplies(on: Boolean) {
        _replies.value = on
        save { it.copy(pushNotifyReplies = on) }
    }

    fun toggleDMs(on: Boolean) {
        _dms.value = on
        save { it.copy(pushNotifyDMs = on) }
    }

    fun toggleZaps(on: Boolean) {
        _zaps.value = on
        save { it.copy(pushNotifyZaps = on) }
    }

    fun toggleReactions(on: Boolean) {
        _reactions.value = on
        save { it.copy(pushNotifyReactions = on) }
    }

    fun toggleReposts(on: Boolean) {
        _reposts.value = on
        save { it.copy(pushNotifyReposts = on) }
    }

    fun registerNow() {
        pushService.registerIfReady()
    }

    private fun save(
        transform: (com.nostrvault.relay.HavenConfig) -> com.nostrvault.relay.HavenConfig,
    ) {
        viewModelScope.launch {
            configStore.update(transform)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NotificationSettingsScreen(
    onBack: () -> Unit,
    viewModel: NotificationSettingsViewModel = hiltViewModel(),
) {
    val enabled by viewModel.enabled.collectAsState()
    val serverUrl by viewModel.serverUrl.collectAsState()
    val mentions by viewModel.mentions.collectAsState()
    val replies by viewModel.replies.collectAsState()
    val dms by viewModel.dms.collectAsState()
    val zaps by viewModel.zaps.collectAsState()
    val reactions by viewModel.reactions.collectAsState()
    val reposts by viewModel.reposts.collectAsState()
    val status by viewModel.registrationStatus.collectAsState()
    val colors = LocalNostrVaultColors.current

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Push Notifications") },
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
            // Master toggle
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "Enable Push Notifications",
                        color = PrimaryText,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = "Receive notifications when the app is closed",
                        color = SecondaryText,
                        fontSize = 13.sp,
                    )
                }
                Switch(
                    checked = enabled,
                    onCheckedChange = viewModel::toggleEnabled,
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = PrimaryText,
                        checkedTrackColor = colors.primary,
                    ),
                )
            }

            Spacer(Modifier.height(24.dp))

            // Push server URL
            Text(
                text = "Push Server URL",
                color = PrimaryText,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.height(4.dp))
            OutlinedTextField(
                value = serverUrl,
                onValueChange = viewModel::setServerUrl,
                placeholder = { Text("https://push.example.com", color = PlaceholderText) },
                singleLine = true,
                enabled = enabled,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = colors.primary,
                    unfocusedBorderColor = TertiaryGroupedBg,
                    disabledBorderColor = TertiaryGroupedBg,
                    focusedTextColor = PrimaryText,
                    unfocusedTextColor = PrimaryText,
                    disabledTextColor = TertiaryText,
                    cursorColor = colors.primary,
                ),
                modifier = Modifier.fillMaxWidth(),
            )

            Spacer(Modifier.height(8.dp))

            // Registration status
            val statusText = when (status) {
                PushNotificationService.RegistrationStatus.REGISTERED -> "Registered"
                PushNotificationService.RegistrationStatus.REGISTERING -> "Registering..."
                PushNotificationService.RegistrationStatus.FAILED -> "Registration failed"
                PushNotificationService.RegistrationStatus.UNREGISTERED -> "Not registered"
            }
            val statusColor = when (status) {
                PushNotificationService.RegistrationStatus.REGISTERED -> SuccessGreen
                PushNotificationService.RegistrationStatus.FAILED -> ErrorRed
                else -> TertiaryText
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "Status: $statusText",
                    color = statusColor,
                    fontSize = 13.sp,
                )
                if (enabled && status != PushNotificationService.RegistrationStatus.REGISTERING) {
                    Spacer(Modifier.width(12.dp))
                    TextButton(onClick = viewModel::registerNow) {
                        Text(
                            text = "Register Now",
                            color = colors.primary,
                            fontSize = 13.sp,
                        )
                    }
                }
            }

            Spacer(Modifier.height(32.dp))

            // Notification type toggles
            Text(
                text = "NOTIFICATION TYPES",
                color = SecondaryText,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                letterSpacing = 1.sp,
            )
            Spacer(Modifier.height(12.dp))

            Surface(
                shape = RoundedCornerShape(12.dp),
                color = SecondaryGroupedBg,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column {
                    NotificationToggle(
                        title = "Mentions",
                        subtitle = "When someone mentions you in a note",
                        checked = mentions,
                        enabled = enabled,
                        onToggle = viewModel::toggleMentions,
                    )
                    HorizontalDivider(color = TertiaryGroupedBg, thickness = 0.5.dp)
                    NotificationToggle(
                        title = "Replies",
                        subtitle = "Replies to your notes",
                        checked = replies,
                        enabled = enabled,
                        onToggle = viewModel::toggleReplies,
                    )
                    HorizontalDivider(color = TertiaryGroupedBg, thickness = 0.5.dp)
                    NotificationToggle(
                        title = "Direct Messages",
                        subtitle = "New DMs from contacts",
                        checked = dms,
                        enabled = enabled,
                        onToggle = viewModel::toggleDMs,
                    )
                    HorizontalDivider(color = TertiaryGroupedBg, thickness = 0.5.dp)
                    NotificationToggle(
                        title = "Zaps",
                        subtitle = "When someone zaps your notes",
                        checked = zaps,
                        enabled = enabled,
                        onToggle = viewModel::toggleZaps,
                    )
                    HorizontalDivider(color = TertiaryGroupedBg, thickness = 0.5.dp)
                    NotificationToggle(
                        title = "Reactions",
                        subtitle = "Likes and reactions to your notes",
                        checked = reactions,
                        enabled = enabled,
                        onToggle = viewModel::toggleReactions,
                    )
                    HorizontalDivider(color = TertiaryGroupedBg, thickness = 0.5.dp)
                    NotificationToggle(
                        title = "Reposts",
                        subtitle = "When someone reposts your notes",
                        checked = reposts,
                        enabled = enabled,
                        onToggle = viewModel::toggleReposts,
                    )
                }
            }

            Spacer(Modifier.height(16.dp))

            Text(
                text = "Push notifications require a compatible push server and Firebase Cloud Messaging. " +
                    "The push server receives your pubkey and device token to deliver notifications.",
                color = TertiaryText,
                fontSize = 12.sp,
            )
        }
    }
}

@Composable
private fun NotificationToggle(
    title: String,
    subtitle: String,
    checked: Boolean,
    enabled: Boolean,
    onToggle: (Boolean) -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                color = if (enabled) PrimaryText else TertiaryText,
                fontSize = 15.sp,
            )
            Text(
                text = subtitle,
                color = if (enabled) SecondaryText else TertiaryText,
                fontSize = 12.sp,
            )
        }
        Switch(
            checked = checked,
            onCheckedChange = onToggle,
            enabled = enabled,
            colors = SwitchDefaults.colors(
                checkedThumbColor = PrimaryText,
                checkedTrackColor = LocalNostrVaultColors.current.primary,
                uncheckedThumbColor = SecondaryText,
                uncheckedTrackColor = TertiaryGroupedBg,
            ),
        )
    }
}
