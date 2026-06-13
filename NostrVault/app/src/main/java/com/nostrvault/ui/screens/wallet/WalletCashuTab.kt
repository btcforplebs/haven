package com.nostrvault.ui.screens.wallet

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.screens.WalletCaption
import com.nostrvault.ui.screens.WalletQr
import com.nostrvault.ui.screens.WalletSectionLabel
import com.nostrvault.ui.screens.WalletViewModel
import com.nostrvault.ui.screens.walletFieldColors
import com.nostrvault.ui.theme.*

/**
 * Cashu ecash tab: balance, Lightning bridge (fund / cash-out), token send/receive,
 * bearer instruments list, restore-from-relays and pending-quote recovery.
 * Port of iOS WalletCashuTab.
 */
@Composable
fun WalletCashuTab(viewModel: WalletViewModel) {
    val config by viewModel.config.collectAsState()
    val balance by viewModel.cashuBalance.collectAsState()
    val proofs by viewModel.cashuProofs.collectAsState()
    val mintInfo by viewModel.cashuMintInfo.collectAsState()
    val busy by viewModel.busy.collectAsState()
    val fundInvoice by viewModel.fundInvoice.collectAsState()
    val sendToken by viewModel.sendToken.collectAsState()
    val colors = LocalNostrVaultColors.current
    val clipboard = LocalClipboardManager.current

    // Point the service at the saved mint when this tab opens / the mint changes.
    LaunchedEffect(config.cashuMintURL) { viewModel.ensureMintConfigured() }

    if (config.cashuMintURL.isBlank()) {
        Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
            Text(
                "Set a Cashu mint in the Settings tab to use ecash.",
                color = SecondaryText, fontSize = 14.sp,
            )
        }
        return
    }

    var fundAmount by remember { mutableStateOf("") }
    var cashOutInvoice by remember { mutableStateOf("") }
    var sendAmount by remember { mutableStateOf("") }
    var sendMemo by remember { mutableStateOf("") }
    var receiveToken by remember { mutableStateOf("") }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
    ) {
        // Beta notice
        Surface(
            color = WarningYellow.copy(alpha = 0.12f),
            shape = RoundedCornerShape(8.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(
                "Ecash is experimental. Keep only small amounts in the mint.",
                color = WarningYellow, fontSize = 12.sp, modifier = Modifier.padding(10.dp),
            )
        }

        Spacer(Modifier.height(16.dp))

        // Balance + mint
        Column {
            Text("Ecash Balance", color = SecondaryText, fontSize = 12.sp)
            Text(
                text = "$balance sats",
                color = PrimaryText, fontSize = 24.sp, fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace,
            )
            mintInfo?.name?.let { Text(it, color = SecondaryText, fontSize = 12.sp) }
        }

        Spacer(Modifier.height(24.dp))

        // ── Fund (Lightning → ecash) ──────────────────────────────
        WalletSectionLabel("Fund from Lightning")
        if (fundInvoice == null) {
            OutlinedTextField(
                value = fundAmount,
                onValueChange = { t -> fundAmount = t.filter { it.isDigit() } },
                label = { Text("Amount (sats)") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.fillMaxWidth(),
                colors = walletFieldColors(colors.primary),
            )
            Spacer(Modifier.height(12.dp))
            Button(
                onClick = { viewModel.fundFromLightning(fundAmount.toLongOrNull() ?: 0L) },
                enabled = !busy && (fundAmount.toLongOrNull() ?: 0L) > 0,
                colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                modifier = Modifier.fillMaxWidth(),
            ) { Text(if (busy) "Working…" else "Generate Invoice") }
        } else {
            Text("Pay this invoice, then tokens are minted automatically:", color = SecondaryText, fontSize = 12.sp)
            Spacer(Modifier.height(8.dp))
            WalletQr(fundInvoice!!)
            Spacer(Modifier.height(8.dp))
            Text(fundInvoice!!, color = SecondaryText, fontSize = 11.sp, fontFamily = FontFamily.Monospace, maxLines = 3)
            Spacer(Modifier.height(8.dp))
            Row {
                OutlinedButton(onClick = { clipboard.setText(AnnotatedString(fundInvoice!!)) }) { Text("Copy") }
                Spacer(Modifier.width(8.dp))
                TextButton(onClick = { viewModel.clearFundInvoice(); fundAmount = "" }) {
                    Text("Done", color = colors.primary)
                }
            }
        }

        Spacer(Modifier.height(24.dp))

        // ── Cash out (ecash → Lightning) ──────────────────────────
        WalletSectionLabel("Cash Out to Lightning")
        OutlinedTextField(
            value = cashOutInvoice,
            onValueChange = { cashOutInvoice = it },
            label = { Text("Paste a bolt11 invoice") },
            modifier = Modifier.fillMaxWidth(),
            minLines = 2,
            colors = walletFieldColors(colors.primary),
        )
        Spacer(Modifier.height(12.dp))
        Button(
            onClick = { viewModel.cashOut(cashOutInvoice); cashOutInvoice = "" },
            enabled = !busy && cashOutInvoice.isNotBlank(),
            colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
            modifier = Modifier.fillMaxWidth(),
        ) { Text(if (busy) "Paying…" else "Pay Invoice") }

        Spacer(Modifier.height(24.dp))

        // ── Send token ────────────────────────────────────────────
        WalletSectionLabel("Send Ecash Token")
        if (sendToken == null) {
            OutlinedTextField(
                value = sendAmount,
                onValueChange = { t -> sendAmount = t.filter { it.isDigit() } },
                label = { Text("Amount (sats)") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.fillMaxWidth(),
                colors = walletFieldColors(colors.primary),
            )
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = sendMemo,
                onValueChange = { sendMemo = it },
                label = { Text("Memo (optional)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                colors = walletFieldColors(colors.primary),
            )
            Spacer(Modifier.height(12.dp))
            Button(
                onClick = { viewModel.createCashuToken(sendAmount.toLongOrNull() ?: 0L, sendMemo) },
                enabled = !busy && (sendAmount.toLongOrNull() ?: 0L) > 0,
                colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                modifier = Modifier.fillMaxWidth(),
            ) { Text(if (busy) "Working…" else "Create Token") }
        } else {
            Text(sendToken!!, color = SecondaryText, fontSize = 11.sp, fontFamily = FontFamily.Monospace, maxLines = 4)
            Spacer(Modifier.height(8.dp))
            Row {
                OutlinedButton(onClick = { clipboard.setText(AnnotatedString(sendToken!!)) }) { Text("Copy Token") }
                Spacer(Modifier.width(8.dp))
                TextButton(onClick = { viewModel.clearSendToken(); sendAmount = ""; sendMemo = "" }) {
                    Text("Done", color = colors.primary)
                }
            }
        }

        Spacer(Modifier.height(24.dp))

        // ── Receive token ─────────────────────────────────────────
        WalletSectionLabel("Receive Ecash Token")
        OutlinedTextField(
            value = receiveToken,
            onValueChange = { receiveToken = it },
            label = { Text("Paste a cashu… token") },
            modifier = Modifier.fillMaxWidth(),
            minLines = 2,
            colors = walletFieldColors(colors.primary),
        )
        Spacer(Modifier.height(12.dp))
        Button(
            onClick = { viewModel.receiveCashuToken(receiveToken); receiveToken = "" },
            enabled = !busy && receiveToken.isNotBlank(),
            colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
            modifier = Modifier.fillMaxWidth(),
        ) { Text(if (busy) "Redeeming…" else "Redeem Token") }

        Spacer(Modifier.height(24.dp))

        // ── Bearer instruments ────────────────────────────────────
        WalletSectionLabel("Bearer Instruments (${proofs.size})")
        if (proofs.isEmpty()) {
            WalletCaption("No unspent proofs.")
        } else {
            Surface(
                color = SecondaryGroupedBg,
                shape = RoundedCornerShape(10.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(modifier = Modifier.padding(12.dp)) {
                    proofs.take(50).forEach { proof ->
                        Row(modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
                            Text("${proof.amount} sats", color = PrimaryText, fontSize = 13.sp,
                                modifier = Modifier.weight(1f))
                            Text(proof.id.take(10), color = SecondaryText, fontSize = 11.sp,
                                fontFamily = FontFamily.Monospace)
                        }
                    }
                }
            }
        }

        Spacer(Modifier.height(24.dp))

        // ── Maintenance ───────────────────────────────────────────
        Row {
            OutlinedButton(onClick = viewModel::restoreCashu, enabled = !busy, modifier = Modifier.weight(1f)) {
                Text("Restore from Relays")
            }
            Spacer(Modifier.width(8.dp))
            OutlinedButton(onClick = viewModel::recoverPending, enabled = !busy, modifier = Modifier.weight(1f)) {
                Text("Recover Pending")
            }
        }

        Spacer(Modifier.height(32.dp))
    }
}
