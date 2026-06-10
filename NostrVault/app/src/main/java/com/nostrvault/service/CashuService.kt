package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.HavenBridge
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Cashu ecash protocol service.
 * Implements NUT-00 through NUT-07 for Lightning-to-ecash swaps
 * with blind signature cryptography and NIP-60 relay storage.
 *
 * Port of CashuService.swift.
 */
@Singleton
class CashuService @Inject constructor(
    private val configStore: ConfigStore,
    private val credentialStore: CredentialStore,
    private val nostrService: NostrService,
) {
    companion object {
        private const val TAG = "CashuService"
        private const val TOKEN_PREFIX = "cashuA"
        private const val WALLET_EVENT_KIND = 37375
        private const val TOKEN_EVENT_KIND = 7375
        private const val HISTORY_EVENT_KIND = 7376
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val json = Json { ignoreUnknownKeys = true }
    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    // ── Observable state ──────────────────────────────────────────────

    private val _proofs = MutableStateFlow<List<CashuProof>>(emptyList())
    val proofs: StateFlow<List<CashuProof>> = _proofs.asStateFlow()

    private val _balanceSats = MutableStateFlow(0UL)
    val balanceSats: StateFlow<ULong> = _balanceSats.asStateFlow()

    private val _activeKeysetId = MutableStateFlow("")
    val activeKeysetId: StateFlow<String> = _activeKeysetId.asStateFlow()

    private val _mintInfo = MutableStateFlow<CashuMintInfo?>(null)
    val mintInfo: StateFlow<CashuMintInfo?> = _mintInfo.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    // ── Internal state ────────────────────────────────────────────────

    private val keysets = mutableMapOf<String, CashuKeyset>()
    private var mintURL: String? = null
    private val tokenEventIds = mutableMapOf<String, String>()
    private val pendingMintQuotes = mutableListOf<PendingMintQuote>()
    private var isRecovering = false

    val hasMint: Boolean get() = mintURL != null
    val mintURLString: String get() = mintURL ?: ""

    // ══════════════════════════════════════════════════════════════════
    // Configuration
    // ══════════════════════════════════════════════════════════════════

    fun configureMint(urlString: String) {
        mintURL = urlString.trimEnd('/')
        loadLocalState()
    }

    // ══════════════════════════════════════════════════════════════════
    // Mint Info (NUT-06)
    // ══════════════════════════════════════════════════════════════════

    suspend fun fetchMintInfo(): CashuMintInfo = withContext(Dispatchers.IO) {
        val url = mintURL ?: throw CashuError("No mint configured")
        val request = Request.Builder().url("$url/v1/info").get().build()
        val response = httpClient.newCall(request).execute()
        if (!response.isSuccessful) throw CashuError("Mint info fetch failed: ${response.code}")
        val body = response.body?.string() ?: throw CashuError("Empty response")
        val info = json.decodeFromString<CashuMintInfo>(body)
        _mintInfo.value = info
        info
    }

    // ══════════════════════════════════════════════════════════════════
    // Keys (NUT-01, NUT-02)
    // ══════════════════════════════════════════════════════════════════

    suspend fun fetchActiveKeys(): CashuKeyset = withContext(Dispatchers.IO) {
        val url = mintURL ?: throw CashuError("No mint configured")
        val request = Request.Builder().url("$url/v1/keys").get().build()
        val response = httpClient.newCall(request).execute()
        if (!response.isSuccessful) throw CashuError("Keys fetch failed: ${response.code}")
        val body = response.body?.string() ?: throw CashuError("Empty response")

        val parsed = json.parseToJsonElement(body).jsonObject
        val keysetArray = parsed["keysets"]?.jsonArray ?: throw CashuError("No keysets in response")
        if (keysetArray.isEmpty()) throw CashuError("Empty keysets")

        val first = keysetArray[0].jsonObject
        val keysetId = first["id"]?.jsonPrimitive?.contentOrNull ?: ""
        val keys = first["keys"]?.jsonObject?.map { (amount, pubkey) ->
            amount to pubkey.jsonPrimitive.content
        }?.toMap() ?: emptyMap()

        val keyset = CashuKeyset(id = keysetId, keys = keys)
        keysets[keysetId] = keyset
        _activeKeysetId.value = keysetId
        keyset
    }

    suspend fun fetchKeysets(): List<CashuKeysetInfo> = withContext(Dispatchers.IO) {
        val url = mintURL ?: throw CashuError("No mint configured")
        val request = Request.Builder().url("$url/v1/keysets").get().build()
        val response = httpClient.newCall(request).execute()
        if (!response.isSuccessful) throw CashuError("Keysets fetch failed: ${response.code}")
        val body = response.body?.string() ?: throw CashuError("Empty response")
        val parsed = json.parseToJsonElement(body).jsonObject
        val keysetArray = parsed["keysets"]?.jsonArray ?: throw CashuError("No keysets")

        keysetArray.map { elem ->
            val obj = elem.jsonObject
            CashuKeysetInfo(
                id = obj["id"]?.jsonPrimitive?.contentOrNull ?: "",
                unit = obj["unit"]?.jsonPrimitive?.contentOrNull ?: "sat",
                active = obj["active"]?.jsonPrimitive?.booleanOrNull ?: false,
            )
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Mint Tokens (NUT-04): Lightning → Ecash
    // ══════════════════════════════════════════════════════════════════

    suspend fun requestMintQuote(amountSats: ULong): CashuMintQuote = withContext(Dispatchers.IO) {
        val url = mintURL ?: throw CashuError("No mint configured")
        val body = """{"amount":$amountSats,"unit":"sat"}"""
        val request = Request.Builder()
            .url("$url/v1/mint/quote/bolt11")
            .post(body.toRequestBody("application/json".toMediaType()))
            .build()

        val response = httpClient.newCall(request).execute()
        if (!response.isSuccessful) throw CashuError("Mint quote failed: ${response.code}")
        val respBody = response.body?.string() ?: throw CashuError("Empty response")
        json.decodeFromString<CashuMintQuote>(respBody)
    }

    suspend fun checkMintQuote(quoteId: String): CashuMintQuote = withContext(Dispatchers.IO) {
        val url = mintURL ?: throw CashuError("No mint configured")
        val request = Request.Builder()
            .url("$url/v1/mint/quote/bolt11/$quoteId")
            .get()
            .build()

        val response = httpClient.newCall(request).execute()
        if (!response.isSuccessful) throw CashuError("Quote check failed: ${response.code}")
        val respBody = response.body?.string() ?: throw CashuError("Empty response")
        json.decodeFromString<CashuMintQuote>(respBody)
    }

    suspend fun mintTokens(quoteId: String, amountSats: ULong) = withContext(Dispatchers.IO) {
        val amounts = splitAmount(amountSats)
        val blindedMessages = mutableListOf<BlindedMessage>()
        val secrets = mutableListOf<ByteArray>()
        val blindingFactors = mutableListOf<ByteArray>()

        for (amount in amounts) {
            val secret = generateSecret()
            secrets.add(secret)

            val (blindedPoint, blindingFactor) = createBlindedMessage(secret)
            blindingFactors.add(blindingFactor)

            blindedMessages.add(
                BlindedMessage(
                    amount = amount,
                    id = _activeKeysetId.value,
                    B_ = blindedPoint.toHexString(),
                )
            )
        }

        val body = json.encodeToString(
            MintRequest.serializer(),
            MintRequest(quote = quoteId, outputs = blindedMessages),
        )
        val url = mintURL ?: throw CashuError("No mint configured")
        val request = Request.Builder()
            .url("$url/v1/mint/bolt11")
            .post(body.toRequestBody("application/json".toMediaType()))
            .build()

        val response = httpClient.newCall(request).execute()
        if (!response.isSuccessful) throw CashuError("Mint failed: ${response.code}")
        val respBody = response.body?.string() ?: throw CashuError("Empty response")

        val mintResponse = json.parseToJsonElement(respBody).jsonObject
        val signatures = mintResponse["signatures"]?.jsonArray
            ?: throw CashuError("No signatures in mint response")

        // Unblind signatures to create proofs
        val newProofs = signatures.mapIndexed { index, sig ->
            val sigObj = sig.jsonObject
            val blindedSig = sigObj["C_"]?.jsonPrimitive?.contentOrNull
                ?: throw CashuError("Missing C_ in signature")
            val amount = sigObj["amount"]?.jsonPrimitive?.longOrNull?.toULong()
                ?: amounts[index]

            val keysetId = sigObj["id"]?.jsonPrimitive?.contentOrNull ?: _activeKeysetId.value
            val mintPubkey = keysets[keysetId]?.keys?.get(amount.toString())
                ?: throw CashuError("No mint key for amount $amount")

            val unblinded = unblindSignature(
                blindedSig.hexToByteArray(),
                blindingFactors[index],
                mintPubkey.hexToByteArray(),
            )

            CashuProof(
                id = keysetId,
                amount = amount,
                secret = secrets[index].toHexString(),
                C = unblinded.toHexString(),
            )
        }

        // Add proofs to wallet
        _proofs.value = _proofs.value + newProofs
        recalculateBalance()
        saveLocalState()
        publishTokenEvent(newProofs)
    }

    // ══════════════════════════════════════════════════════════════════
    // Melt Tokens (NUT-05): Ecash → Lightning
    // ══════════════════════════════════════════════════════════════════

    suspend fun requestMeltQuote(bolt11: String): CashuMeltQuote = withContext(Dispatchers.IO) {
        val url = mintURL ?: throw CashuError("No mint configured")
        val body = """{"request":"$bolt11","unit":"sat"}"""
        val request = Request.Builder()
            .url("$url/v1/melt/quote/bolt11")
            .post(body.toRequestBody("application/json".toMediaType()))
            .build()

        val response = httpClient.newCall(request).execute()
        if (!response.isSuccessful) throw CashuError("Melt quote failed: ${response.code}")
        val respBody = response.body?.string() ?: throw CashuError("Empty response")
        json.decodeFromString<CashuMeltQuote>(respBody)
    }

    suspend fun meltTokens(
        quoteId: String,
        amount: ULong,
        feeReserve: ULong,
    ): Boolean = withContext(Dispatchers.IO) {
        val totalNeeded = amount + feeReserve
        val selection = selectProofs(totalNeeded) ?: throw CashuError("Insufficient balance")

        val body = json.encodeToString(
            MeltRequest.serializer(),
            MeltRequest(quote = quoteId, inputs = selection.selected),
        )

        val url = mintURL ?: throw CashuError("No mint configured")
        val request = Request.Builder()
            .url("$url/v1/melt/bolt11")
            .post(body.toRequestBody("application/json".toMediaType()))
            .build()

        val response = httpClient.newCall(request).execute()
        if (!response.isSuccessful) throw CashuError("Melt failed: ${response.code}")

        // Remove spent proofs
        val spentSecrets = selection.selected.map { it.secret }.toSet()
        _proofs.value = _proofs.value.filter { it.secret !in spentSecrets }
        recalculateBalance()
        saveLocalState()

        true
    }

    // ══════════════════════════════════════════════════════════════════
    // Swap (NUT-03)
    // ══════════════════════════════════════════════════════════════════

    suspend fun swap(
        inputs: List<CashuProof>,
        outputAmounts: List<ULong>,
    ): List<CashuProof> = withContext(Dispatchers.IO) {
        val blindedMessages = mutableListOf<BlindedMessage>()
        val secrets = mutableListOf<ByteArray>()
        val blindingFactors = mutableListOf<ByteArray>()

        for (amount in outputAmounts) {
            val secret = generateSecret()
            secrets.add(secret)
            val (blindedPoint, factor) = createBlindedMessage(secret)
            blindingFactors.add(factor)
            blindedMessages.add(BlindedMessage(amount = amount, id = _activeKeysetId.value, B_ = blindedPoint.toHexString()))
        }

        val body = json.encodeToString(
            SwapRequest.serializer(),
            SwapRequest(inputs = inputs, outputs = blindedMessages),
        )

        val url = mintURL ?: throw CashuError("No mint configured")
        val request = Request.Builder()
            .url("$url/v1/swap")
            .post(body.toRequestBody("application/json".toMediaType()))
            .build()

        val response = httpClient.newCall(request).execute()
        if (!response.isSuccessful) throw CashuError("Swap failed: ${response.code}")
        val respBody = response.body?.string() ?: throw CashuError("Empty response")

        val swapResponse = json.parseToJsonElement(respBody).jsonObject
        val signatures = swapResponse["signatures"]?.jsonArray
            ?: throw CashuError("No signatures in swap response")

        signatures.mapIndexed { index, sig ->
            val sigObj = sig.jsonObject
            val blindedSig = sigObj["C_"]?.jsonPrimitive?.contentOrNull ?: ""
            val amount = sigObj["amount"]?.jsonPrimitive?.longOrNull?.toULong() ?: outputAmounts[index]
            val keysetId = sigObj["id"]?.jsonPrimitive?.contentOrNull ?: _activeKeysetId.value
            val mintPubkey = keysets[keysetId]?.keys?.get(amount.toString()) ?: ""

            val unblinded = if (mintPubkey.isNotEmpty()) {
                unblindSignature(blindedSig.hexToByteArray(), blindingFactors[index], mintPubkey.hexToByteArray())
            } else blindedSig.hexToByteArray()

            CashuProof(id = keysetId, amount = amount, secret = secrets[index].toHexString(), C = unblinded.toHexString())
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Token encoding / decoding
    // ══════════════════════════════════════════════════════════════════

    fun encodeToken(proofs: List<CashuProof>, memo: String? = null): String {
        val tokenData = CashuTokenData(
            token = listOf(CashuTokenProof(mint = mintURLString, proofs = proofs)),
            memo = memo,
        )
        val jsonStr = json.encodeToString(CashuTokenData.serializer(), tokenData)
        val encoded = android.util.Base64.encodeToString(
            jsonStr.toByteArray(), android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP
        )
        return "$TOKEN_PREFIX$encoded"
    }

    fun decodeToken(tokenString: String): Pair<List<CashuTokenProof>, String?> {
        if (!tokenString.startsWith(TOKEN_PREFIX)) throw CashuError("Invalid token prefix")
        val encoded = tokenString.removePrefix(TOKEN_PREFIX)
        val decoded = android.util.Base64.decode(encoded, android.util.Base64.URL_SAFE)
        val tokenData = json.decodeFromString<CashuTokenData>(String(decoded))
        return tokenData.token to tokenData.memo
    }

    suspend fun createSendToken(amountSats: ULong, memo: String? = null): String {
        val selection = selectProofs(amountSats) ?: throw CashuError("Insufficient balance")

        val sendProofs: List<CashuProof>
        if (selection.change.isNotEmpty()) {
            // Need swap for exact denomination
            val swapped = swap(selection.selected, listOf(amountSats) + selection.change.map { it.amount })
            sendProofs = swapped.take(1)
            val changeProofs = swapped.drop(1)

            // Remove old proofs, add change
            val oldSecrets = selection.selected.map { it.secret }.toSet()
            _proofs.value = _proofs.value.filter { it.secret !in oldSecrets } + changeProofs
        } else {
            sendProofs = selection.selected
            val oldSecrets = sendProofs.map { it.secret }.toSet()
            _proofs.value = _proofs.value.filter { it.secret !in oldSecrets }
        }

        recalculateBalance()
        saveLocalState()
        return encodeToken(sendProofs, memo)
    }

    suspend fun receiveToken(tokenString: String) {
        val (tokenProofs, _) = decodeToken(tokenString)
        val receivedProofs = tokenProofs.flatMap { it.proofs }

        // Swap for fresh proofs (prevents sender double-spend)
        val amounts = receivedProofs.map { it.amount }
        val freshProofs = swap(receivedProofs, amounts)

        _proofs.value = _proofs.value + freshProofs
        recalculateBalance()
        saveLocalState()
        publishTokenEvent(freshProofs)
    }

    // ══════════════════════════════════════════════════════════════════
    // Proof state checking (NUT-07)
    // ══════════════════════════════════════════════════════════════════

    suspend fun checkProofStates() = withContext(Dispatchers.IO) {
        val url = mintURL ?: return@withContext
        val currentProofs = _proofs.value
        if (currentProofs.isEmpty()) return@withContext

        val ys = currentProofs.map { it.secret }
        val ysJson = kotlinx.serialization.json.JsonArray(ys.map { kotlinx.serialization.json.JsonPrimitive(it) })
        val body = """{"Ys":$ysJson}"""
        val request = Request.Builder()
            .url("$url/v1/checkstate")
            .post(body.toRequestBody("application/json".toMediaType()))
            .build()

        val response = httpClient.newCall(request).execute()
        if (!response.isSuccessful) return@withContext

        val respBody = response.body?.string() ?: return@withContext
        val states = json.parseToJsonElement(respBody).jsonObject["states"]?.jsonArray ?: return@withContext

        val spentSecrets = mutableSetOf<String>()
        states.forEachIndexed { index, state ->
            val stateStr = state.jsonObject["state"]?.jsonPrimitive?.contentOrNull
            if (stateStr == "SPENT" && index < ys.size) {
                spentSecrets.add(ys[index])
            }
        }

        if (spentSecrets.isNotEmpty()) {
            _proofs.value = _proofs.value.filter { it.secret !in spentSecrets }
            recalculateBalance()
            saveLocalState()
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // NIP-60 relay storage
    // ══════════════════════════════════════════════════════════════════

    fun publishWalletEvent() {
        scope.launch(Dispatchers.IO) {
            val tags = listOf(
                listOf("d", "cashu"),
            )
            val event = nostrService.signEvent(
                kind = WALLET_EVENT_KIND, content = "", tags = tags, forceOwner = true,
            ) ?: return@launch
            nostrService.postEvent(event)
        }
    }

    fun publishTokenEvent(newProofs: List<CashuProof>) {
        scope.launch(Dispatchers.IO) {
            val proofJson = json.encodeToString(
                kotlinx.serialization.builtins.ListSerializer(CashuProof.serializer()),
                newProofs,
            )
            // Encrypt to self using NIP-44
            val ownerPubkey = nostrService.ownerHexPubkey
            val ownerPrivkey = nostrService.resolveOwnerSecretKey() ?: return@launch
            val encrypted = NIP44Service.encrypt(proofJson, ownerPubkey, ownerPrivkey) ?: return@launch

            val tags = listOf(
                listOf("a", "$WALLET_EVENT_KIND:$ownerPubkey:cashu"),
            )
            val event = nostrService.signEvent(
                kind = TOKEN_EVENT_KIND, content = encrypted, tags = tags, forceOwner = true,
            ) ?: return@launch
            nostrService.postEvent(event)
        }
    }

    fun publishHistoryEvent(direction: String, amount: ULong, memo: String?) {
        scope.launch(Dispatchers.IO) {
            val tags = mutableListOf(
                listOf("direction", direction),
                listOf("amount", amount.toString()),
            )
            memo?.let { tags.add(listOf("memo", it)) }

            val event = nostrService.signEvent(
                kind = HISTORY_EVENT_KIND, content = "", tags = tags, forceOwner = true,
            ) ?: return@launch
            nostrService.postEvent(event)
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Proof selection & balance
    // ══════════════════════════════════════════════════════════════════

    fun selectProofs(targetAmount: ULong): ProofSelection? {
        val sorted = _proofs.value.sortedByDescending { it.amount }
        val selected = mutableListOf<CashuProof>()
        var total = 0UL

        for (proof in sorted) {
            if (total >= targetAmount) break
            selected.add(proof)
            total += proof.amount
        }

        if (total < targetAmount) return null

        val changeAmount = total - targetAmount
        val change = if (changeAmount > 0UL) {
            splitAmount(changeAmount).map {
                CashuProof(id = _activeKeysetId.value, amount = it, secret = "", C = "")
            }
        } else emptyList()

        return ProofSelection(selected = selected, change = change)
    }

    fun recalculateBalance() {
        _balanceSats.value = _proofs.value.sumOf { it.amount }
    }

    // ══════════════════════════════════════════════════════════════════
    // Cryptographic helpers
    // ══════════════════════════════════════════════════════════════════

    /**
     * Split amount into power-of-2 denominations.
     */
    fun splitAmount(amount: ULong): List<ULong> {
        val result = mutableListOf<ULong>()
        var remaining = amount
        var bit = 1UL
        while (remaining > 0UL) {
            if (remaining and 1UL == 1UL) result.add(bit)
            remaining = remaining shr 1
            bit = bit shl 1
        }
        return result
    }

    private fun generateSecret(): ByteArray {
        val bytes = ByteArray(32)
        SecureRandom().nextBytes(bytes)
        return bytes
    }

    /**
     * Create a blinded message for the mint.
     * B_ = Y + r*G where Y = hash_to_curve(secret)
     */
    private fun createBlindedMessage(secret: ByteArray): Pair<ByteArray, ByteArray> {
        // TODO: Implement via Go backend when cashuBlindMessage JNI is added
        throw CashuError("Cashu blind message not yet implemented in Go backend")
    }

    /**
     * Unblind a mint signature.
     * C = C_ - r*K
     */
    private fun unblindSignature(
        blindedSignature: ByteArray,
        blindingFactor: ByteArray,
        mintPubkey: ByteArray,
    ): ByteArray {
        // TODO: Implement via Go backend when cashuUnblindSignature JNI is added
        throw CashuError("Cashu unblind signature not yet implemented in Go backend")
    }

    // ══════════════════════════════════════════════════════════════════
    // Persistence
    // ══════════════════════════════════════════════════════════════════

    private fun saveLocalState() {
        scope.launch(Dispatchers.IO) {
            try {
                val dir = configStore.config.value.appSupportDir ?: return@launch
                val state = CashuWalletState(
                    proofs = _proofs.value,
                    activeKeysetId = _activeKeysetId.value,
                    mintURL = mintURL,
                )
                val file = File(dir, "cashu_wallet_state.json")
                file.writeText(json.encodeToString(CashuWalletState.serializer(), state))
            } catch (e: Exception) {
                Log.w(TAG, "Cashu state save failed: ${e.message}")
            }
        }
    }

    private fun loadLocalState() {
        scope.launch(Dispatchers.IO) {
            try {
                val dir = configStore.config.value.appSupportDir ?: return@launch
                val file = File(dir, "cashu_wallet_state.json")
                if (!file.exists()) return@launch

                val state = json.decodeFromString<CashuWalletState>(file.readText())
                withContext(Dispatchers.Main.immediate) {
                    _proofs.value = state.proofs
                    _activeKeysetId.value = state.activeKeysetId
                    mintURL = state.mintURL
                    recalculateBalance()
                }
            } catch (e: Exception) {
                Log.w(TAG, "Cashu state load failed: ${e.message}")
            }
        }
    }
}

// ── Extension helpers ─────────────────────────────────────────────

private fun ByteArray.toHexString(): String = joinToString("") { "%02x".format(it) }

private fun String.hexToByteArray(): ByteArray {
    val len = length
    val data = ByteArray(len / 2)
    for (i in 0 until len step 2) {
        data[i / 2] = ((Character.digit(this[i], 16) shl 4) + Character.digit(this[i + 1], 16)).toByte()
    }
    return data
}

// ── Data models ───────────────────────────────────────────────────

@Serializable
data class CashuProof(
    val id: String,
    val amount: ULong,
    val secret: String,
    val C: String,
)

@Serializable
data class CashuKeyset(
    val id: String,
    val keys: Map<String, String>,
)

@Serializable
data class CashuKeysetInfo(
    val id: String,
    val unit: String,
    val active: Boolean,
)

@Serializable
data class CashuMintInfo(
    val name: String? = null,
    val pubkey: String? = null,
    val version: String? = null,
    val description: String? = null,
    val nuts: JsonObject? = null,
)

@Serializable
data class CashuMintQuote(
    val quote: String,
    val request: String, // BOLT11 invoice
    val state: String? = null,
    val paid: Boolean? = null,
    val expiry: Long? = null,
)

@Serializable
data class CashuMeltQuote(
    val quote: String,
    val amount: Long,
    val fee_reserve: Long,
    val state: String? = null,
    val paid: Boolean? = null,
)

@Serializable
data class BlindedMessage(
    val amount: ULong,
    val id: String,
    val B_: String,
)

@Serializable
data class MintRequest(
    val quote: String,
    val outputs: List<BlindedMessage>,
)

@Serializable
data class MeltRequest(
    val quote: String,
    val inputs: List<CashuProof>,
)

@Serializable
data class SwapRequest(
    val inputs: List<CashuProof>,
    val outputs: List<BlindedMessage>,
)

@Serializable
data class CashuTokenData(
    val token: List<CashuTokenProof>,
    val memo: String? = null,
)

@Serializable
data class CashuTokenProof(
    val mint: String,
    val proofs: List<CashuProof>,
)

data class ProofSelection(
    val selected: List<CashuProof>,
    val change: List<CashuProof>,
)

data class PendingMintQuote(
    val quote: CashuMintQuote,
    val amountSats: ULong,
)

@Serializable
data class CashuWalletState(
    val proofs: List<CashuProof>,
    val activeKeysetId: String,
    val mintURL: String?,
)

class CashuError(message: String) : Exception(message)
