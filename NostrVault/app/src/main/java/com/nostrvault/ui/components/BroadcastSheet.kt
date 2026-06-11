package com.nostrvault.ui.components

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedNote
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*

/**
 * Broadcast sheet for publishing a note to multiple relays.
 * Port of iOS EventBroadcastSheet.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BroadcastSheet(
    note: FeedNote,
    sheetState: SheetState,
    feedService: FeedService,
    nostrService: NostrService,
    configStore: ConfigStore,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val colors = LocalNostrVaultColors.current

    val rawEventJson = remember { feedService.getCachedRawEvent(note.id) }
    val blastrRelays = remember { configStore.config.value.activeBlastrRelays }

    var isBroadcasting by remember { mutableStateOf(false) }
    var relayResults by remember { mutableStateOf(mapOf<String, Boolean?>()) }

    // Initialize relay status map
    LaunchedEffect(Unit) {
        relayResults = blastrRelays.associateWith { null }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = SecondaryGroupedBg,
        dragHandle = { BottomSheetDefaults.DragHandle(color = SecondaryText) },
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 32.dp)
                .verticalScroll(rememberScrollState()),
        ) {
            Text(
                text = "Broadcast",
                color = PrimaryText,
                fontWeight = FontWeight.Bold,
                fontSize = 20.sp,
                modifier = Modifier.align(Alignment.CenterHorizontally),
            )

            Spacer(Modifier.height(16.dp))

            // Event ID section
            SectionHeader("EVENT ID")
            CopyableRow(label = "hex", value = note.id, context = context)

            Spacer(Modifier.height(16.dp))

            // Raw JSON section
            if (rawEventJson != null) {
                SectionHeader("RAW EVENT")
                Surface(
                    color = WindowBackground.copy(alpha = 0.5f),
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        text = rawEventJson.take(500) + if (rawEventJson.length > 500) "..." else "",
                        color = SecondaryText,
                        fontSize = 11.sp,
                        fontFamily = FontFamily.Monospace,
                        modifier = Modifier.padding(12.dp),
                        maxLines = 10,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Spacer(Modifier.height(4.dp))
                TextButton(
                    onClick = {
                        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        clipboard.setPrimaryClip(ClipData.newPlainText("Event JSON", rawEventJson))
                    },
                ) {
                    Icon(NostrVaultIcons.Copy, contentDescription = null, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("Copy JSON", fontSize = 13.sp)
                }

                Spacer(Modifier.height(16.dp))
            }

            // Relay list with status
            SectionHeader("RELAYS (${blastrRelays.size})")
            Spacer(Modifier.height(8.dp))

            for (relay in blastrRelays) {
                val status = relayResults[relay]
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 4.dp),
                ) {
                    // Status indicator
                    when (status) {
                        null -> {
                            if (isBroadcasting) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(16.dp),
                                    strokeWidth = 2.dp,
                                    color = colors.primary,
                                )
                            } else {
                                Icon(
                                    NostrVaultIcons.Relay,
                                    contentDescription = null,
                                    tint = SecondaryText,
                                    modifier = Modifier.size(16.dp),
                                )
                            }
                        }
                        true -> Icon(
                            NostrVaultIcons.Check,
                            contentDescription = "Success",
                            tint = SuccessGreen,
                            modifier = Modifier.size(16.dp),
                        )
                        false -> Icon(
                            NostrVaultIcons.Dismiss,
                            contentDescription = "Failed",
                            tint = ErrorRed,
                            modifier = Modifier.size(16.dp),
                        )
                    }

                    Spacer(Modifier.width(8.dp))

                    Text(
                        text = relay.removePrefix("wss://").removePrefix("ws://"),
                        color = PrimaryText,
                        fontSize = 14.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }

            Spacer(Modifier.height(20.dp))

            // Broadcast button
            val succeeded = relayResults.values.count { it == true }
            val total = blastrRelays.size

            Button(
                onClick = {
                    val json = rawEventJson ?: return@Button
                    isBroadcasting = true
                    nostrService.broadcastRawEvent(json) { relay, success ->
                        relayResults = relayResults + (relay to success)
                    }
                },
                enabled = rawEventJson != null && !isBroadcasting,
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = colors.primary,
                    contentColor = PrimaryText,
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .height(50.dp),
            ) {
                Icon(NostrVaultIcons.Send, contentDescription = null, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Text(
                    text = if (isBroadcasting) "Broadcast to $succeeded/$total relays" else "Broadcast to $total relays",
                    fontWeight = FontWeight.Bold,
                    fontSize = 16.sp,
                )
            }

            if (rawEventJson == null) {
                Spacer(Modifier.height(8.dp))
                Text(
                    text = "Raw event not cached. Try viewing the note detail first.",
                    color = SecondaryText,
                    fontSize = 12.sp,
                )
            }
        }
    }
}

@Composable
private fun SectionHeader(text: String) {
    Text(
        text = text,
        color = SecondaryText,
        fontSize = 11.sp,
        fontWeight = FontWeight.Bold,
        letterSpacing = 1.sp,
    )
    Spacer(Modifier.height(4.dp))
}

@Composable
private fun CopyableRow(label: String, value: String, context: Context) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            text = "$label: ${value.take(16)}...",
            color = PrimaryText,
            fontSize = 13.sp,
            fontFamily = FontFamily.Monospace,
            modifier = Modifier.weight(1f),
        )
        TextButton(
            onClick = {
                val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboard.setPrimaryClip(ClipData.newPlainText(label, value))
            },
            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
        ) {
            Icon(NostrVaultIcons.Copy, contentDescription = null, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(4.dp))
            Text("Copy", fontSize = 12.sp)
        }
    }
}
