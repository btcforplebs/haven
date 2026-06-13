package com.nostrvault.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.LikeRed
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryGroupedBg
import com.nostrvault.ui.theme.SecondaryText

/**
 * Content reporting dialog — port of iOS UGCReportingDialog.
 * Lets the user pick a NIP-56 report reason and add optional details.
 * Reporting also blocks the user (handled by the caller).
 */
@Composable
fun UGCReportDialog(
    onReport: (reason: String, description: String) -> Unit,
    onDismiss: () -> Unit,
) {
    val reasons = listOf(
        "Spam" to "spam",
        "Nudity / Sexual Content" to "nudity",
        "Violence / Harm" to "violence",
        "Illegal Content" to "illegal",
        "Impersonation" to "impersonation",
        "Other" to "other",
    )
    var selectedReason by remember { mutableStateOf("spam") }
    var description by remember { mutableStateOf("") }
    val accent = LocalNostrVaultColors.current.primary

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Report Content", color = PrimaryText, fontWeight = FontWeight.Bold) },
        text = {
            Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
                Text(
                    text = "Why are you reporting this?",
                    color = PrimaryText,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.height(8.dp))
                reasons.forEach { (label, value) ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { selectedReason = value }
                            .padding(vertical = 6.dp),
                    ) {
                        RadioButton(
                            selected = selectedReason == value,
                            onClick = { selectedReason = value },
                            colors = RadioButtonDefaults.colors(selectedColor = accent),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(text = label, color = PrimaryText, fontSize = 15.sp)
                    }
                }
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(
                    value = description,
                    onValueChange = { description = it },
                    label = { Text("Additional details (optional)") },
                    modifier = Modifier.fillMaxWidth(),
                    minLines = 2,
                    maxLines = 4,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = PrimaryText,
                        unfocusedTextColor = PrimaryText,
                        cursorColor = accent,
                        focusedBorderColor = accent,
                    ),
                )
                Spacer(Modifier.height(10.dp))
                Text(
                    text = "Reporting will also automatically block this user for you.",
                    color = SecondaryText,
                    fontSize = 12.sp,
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onReport(selectedReason, description.trim()) },
                colors = ButtonDefaults.textButtonColors(contentColor = LikeRed),
            ) { Text("Report & Block") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel", color = SecondaryText) }
        },
        containerColor = SecondaryGroupedBg,
    )
}
