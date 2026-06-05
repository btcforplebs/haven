import Foundation
import CryptoKit
import Security
import SilentPaymentsKit
import Combine

@MainActor
class CashuService: ObservableObject {
    static let shared = CashuService()

    // MARK: - Published State

    @Published var proofs: [CashuProof] = []
    @Published var balanceSats: UInt64 = 0
    @Published var activeKeysetId: String = ""
    @Published var mintInfo: CashuMintInfo? = nil
    @Published var isLoading: Bool = false
    @Published var lastError: String? = nil

    // MARK: - Internal State

    private var keysets: [String: CashuKeyset] = [:]
    private var mintURL: URL? = nil
    private var tokenEventIds: [String: String] = [:]  // proofId -> nostr event id
    private var pendingMintQuotes: [PendingMintQuote] = []
    private var isRecovering = false
    private var cancellables = Set<AnyCancellable>()

    private init() {
        loadState()
    }

    // MARK: - Configuration

    func configureMint(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed), !trimmed.isEmpty else {
            mintURL = nil
            mintInfo = nil
            return
        }
        mintURL = url
    }

    var hasMint: Bool {
        mintURL != nil
    }

    var mintURLString: String {
        mintURL?.absoluteString ?? ""
    }

    // MARK: - Mint Info (NUT-06)

    func fetchMintInfo() async throws -> CashuMintInfo {
        let info: CashuMintInfo = try await mintAPIRequest(method: "GET", path: "/v1/info")
        await MainActor.run { self.mintInfo = info }
        return info
    }

    // MARK: - Keys (NUT-01, NUT-02)

    func fetchActiveKeys() async throws -> CashuKeyset {
        let response: CashuKeysResponse = try await mintAPIRequest(method: "GET", path: "/v1/keys")
        guard let keyset = response.keysets.first(where: { $0.unit == "sat" }) else {
            throw CashuError.noActiveKeyset
        }
        keysets[keyset.id] = keyset
        activeKeysetId = keyset.id
        saveState()
        return keyset
    }

    func fetchKeysets() async throws -> [CashuKeysetInfo] {
        let response: CashuKeysetListResponse = try await mintAPIRequest(method: "GET", path: "/v1/keysets")
        return response.keysets
    }

    // MARK: - Mint Tokens (NUT-04): Lightning -> Ecash

    func requestMintQuote(amountSats: UInt64) async throws -> CashuMintQuote {
        let body = MintQuoteRequest(amount: amountSats, unit: "sat")
        return try await mintAPIRequest(method: "POST", path: "/v1/mint/quote/bolt11", body: body)
    }

    func checkMintQuote(quoteId: String) async throws -> CashuMintQuote {
        return try await mintAPIRequest(method: "GET", path: "/v1/mint/quote/bolt11/\(quoteId)")
    }

    func mintTokens(quoteId: String, amountSats: UInt64) async throws {
        if activeKeysetId.isEmpty {
            _ = try await fetchActiveKeys()
        }

        guard let keyset = keysets[activeKeysetId] else {
            throw CashuError.noActiveKeyset
        }

        let denominations = Self.splitAmount(amountSats)

        var outputs: [BlindedMessage] = []
        var blindingData: [(secret: Data, blindingFactor: Data, amount: UInt64)] = []

        for amount in denominations {
            let secret = generateRandomSecret()
            let (blindedPoint, blindingFactor) = try Self.createBlindedMessage(secret: secret)

            outputs.append(BlindedMessage(
                amount: amount,
                id: activeKeysetId,
                B_: blindedPoint.hexString
            ))
            blindingData.append((secret: secret, blindingFactor: blindingFactor, amount: amount))
        }

        let request = MintRequest(quote: quoteId, outputs: outputs)
        let response: MintResponse = try await mintAPIRequest(method: "POST", path: "/v1/mint/bolt11", body: request)

        guard response.signatures.count == blindingData.count else {
            throw CashuError.proofCreationFailed
        }

        var newProofs: [CashuProof] = []

        for (i, sig) in response.signatures.enumerated() {
            let bd = blindingData[i]

            guard let mintPubkeyHex = keyset.pubkey(forAmount: bd.amount),
                  let mintPubkey = Data(hexString: mintPubkeyHex),
                  let blindedSig = Data(hexString: sig.C_) else {
                throw CashuCryptoError.unblindingFailed
            }

            let C = try Self.unblindSignature(
                blindedSignature: blindedSig,
                blindingFactor: bd.blindingFactor,
                mintPubkey: mintPubkey
            )

            let proof = CashuProof(
                amount: bd.amount,
                keysetId: sig.id,
                secret: bd.secret.hexString,
                C: C.hexString,
                mintURL: mintURLString
            )
            newProofs.append(proof)
        }

        proofs.append(contentsOf: newProofs)
        recalculateBalance()
        saveState()

        // NIP-60: publish token event to relay
        publishTokenEvent(proofs: newProofs)
        publishHistoryEvent(direction: "in", amount: amountSats, memo: "Mint from Lightning")
    }

    // MARK: - Melt Tokens (NUT-05): Ecash -> Lightning

    func requestMeltQuote(bolt11: String) async throws -> CashuMeltQuote {
        let body = MeltQuoteRequest(request: bolt11, unit: "sat")
        return try await mintAPIRequest(method: "POST", path: "/v1/melt/quote/bolt11", body: body)
    }

    func meltTokens(quoteId: String, amount: UInt64, feeReserve: UInt64) async throws -> Bool {
        let totalNeeded = amount + feeReserve

        guard let selection = selectProofs(targetAmount: totalNeeded) else {
            throw CashuError.insufficientBalance
        }

        if activeKeysetId.isEmpty {
            _ = try await fetchActiveKeys()
        }

        guard let keyset = keysets[activeKeysetId] else {
            throw CashuError.noActiveKeyset
        }

        let inputs = selection.selected.map { proof in
            ProofInput(amount: proof.amount, id: proof.keysetId, secret: proof.secret, C: proof.C)
        }

        // Create change outputs if overpaying
        var changeOutputs: [BlindedMessage]? = nil
        var changeBlindingData: [(secret: Data, blindingFactor: Data, amount: UInt64)] = []

        if selection.change > 0 {
            let changeDenoms = Self.splitAmount(selection.change)
            var outputs: [BlindedMessage] = []

            for changeAmount in changeDenoms {
                let secret = generateRandomSecret()
                let (blindedPoint, blindingFactor) = try Self.createBlindedMessage(secret: secret)
                outputs.append(BlindedMessage(
                    amount: changeAmount,
                    id: activeKeysetId,
                    B_: blindedPoint.hexString
                ))
                changeBlindingData.append((secret: secret, blindingFactor: blindingFactor, amount: changeAmount))
            }
            changeOutputs = outputs
        }

        let request = MeltRequest(quote: quoteId, inputs: inputs, outputs: changeOutputs)
        let response: MeltResponse = try await mintAPIRequest(method: "POST", path: "/v1/melt/bolt11", body: request)

        let paid = response.paid ?? (response.state == "PAID")

        if paid {
            // Remove spent proofs
            let spentIds = Set(selection.selected.map { $0.id })
            let spentEventIds = proofs.filter { spentIds.contains($0.id) }.compactMap { tokenEventIds[$0.id] }
            proofs.removeAll { spentIds.contains($0.id) }

            // Delete spent token events from relay
            for eventId in spentEventIds {
                deleteTokenEvent(eventId: eventId)
            }

            // Unblind change proofs
            if let changeSigs = response.change {
                var changeProofs: [CashuProof] = []
                for (i, sig) in changeSigs.enumerated() where i < changeBlindingData.count {
                    let bd = changeBlindingData[i]
                    guard let mintPubkeyHex = keyset.pubkey(forAmount: bd.amount),
                          let mintPubkey = Data(hexString: mintPubkeyHex),
                          let blindedSig = Data(hexString: sig.C_) else { continue }

                    if let C = try? Self.unblindSignature(
                        blindedSignature: blindedSig,
                        blindingFactor: bd.blindingFactor,
                        mintPubkey: mintPubkey
                    ) {
                        changeProofs.append(CashuProof(
                            amount: bd.amount,
                            keysetId: sig.id,
                            secret: bd.secret.hexString,
                            C: C.hexString,
                            mintURL: mintURLString
                        ))
                    }
                }
                if !changeProofs.isEmpty {
                    proofs.append(contentsOf: changeProofs)
                    publishTokenEvent(proofs: changeProofs)
                }
            }

            recalculateBalance()
            saveState()
            publishHistoryEvent(direction: "out", amount: amount, memo: "Melt to Lightning")
        }

        return paid
    }

    // MARK: - Swap (NUT-03)

    func swap(inputs: [CashuProof], outputAmounts: [UInt64]) async throws -> [CashuProof] {
        if activeKeysetId.isEmpty {
            _ = try await fetchActiveKeys()
        }

        guard let keyset = keysets[activeKeysetId] else {
            throw CashuError.noActiveKeyset
        }

        let inputProofs = inputs.map { ProofInput(amount: $0.amount, id: $0.keysetId, secret: $0.secret, C: $0.C) }

        var outputs: [BlindedMessage] = []
        var blindingData: [(secret: Data, blindingFactor: Data, amount: UInt64)] = []

        for amount in outputAmounts {
            let secret = generateRandomSecret()
            let (blindedPoint, blindingFactor) = try Self.createBlindedMessage(secret: secret)
            outputs.append(BlindedMessage(amount: amount, id: activeKeysetId, B_: blindedPoint.hexString))
            blindingData.append((secret: secret, blindingFactor: blindingFactor, amount: amount))
        }

        let request = SwapRequest(inputs: inputProofs, outputs: outputs)
        let response: SwapResponse = try await mintAPIRequest(method: "POST", path: "/v1/swap", body: request)

        var newProofs: [CashuProof] = []

        for (i, sig) in response.signatures.enumerated() where i < blindingData.count {
            let bd = blindingData[i]
            guard let mintPubkeyHex = keyset.pubkey(forAmount: bd.amount),
                  let mintPubkey = Data(hexString: mintPubkeyHex),
                  let blindedSig = Data(hexString: sig.C_) else { continue }

            let C = try Self.unblindSignature(
                blindedSignature: blindedSig,
                blindingFactor: bd.blindingFactor,
                mintPubkey: mintPubkey
            )

            newProofs.append(CashuProof(
                amount: bd.amount,
                keysetId: sig.id,
                secret: bd.secret.hexString,
                C: C.hexString,
                mintURL: mintURLString
            ))
        }

        return newProofs
    }

    // MARK: - Token Send/Receive (NUT-00)

    func createSendToken(amountSats: UInt64, memo: String? = nil) async throws -> String {
        guard let selection = selectProofs(targetAmount: amountSats) else {
            throw CashuError.insufficientBalance
        }

        var sendProofs = selection.selected

        // If we need change, swap for exact amounts
        if selection.change > 0 {
            let targetDenoms = Self.splitAmount(amountSats)
            let changeDenoms = Self.splitAmount(selection.change)
            let allOutputAmounts = targetDenoms + changeDenoms

            let swapped = try await swap(inputs: selection.selected, outputAmounts: allOutputAmounts)

            // First N proofs are the send proofs, rest are change
            sendProofs = Array(swapped.prefix(targetDenoms.count))
            let changeProofs = Array(swapped.dropFirst(targetDenoms.count))

            // Remove old proofs, add change back
            let oldIds = Set(selection.selected.map { $0.id })
            let oldEventIds = proofs.filter { oldIds.contains($0.id) }.compactMap { tokenEventIds[$0.id] }
            proofs.removeAll { oldIds.contains($0.id) }
            proofs.append(contentsOf: changeProofs)

            for eventId in oldEventIds {
                deleteTokenEvent(eventId: eventId)
            }
            if !changeProofs.isEmpty {
                publishTokenEvent(proofs: changeProofs)
            }
        } else {
            // Exact match - remove proofs from wallet
            let sendIds = Set(sendProofs.map { $0.id })
            let sendEventIds = proofs.filter { sendIds.contains($0.id) }.compactMap { tokenEventIds[$0.id] }
            proofs.removeAll { sendIds.contains($0.id) }
            for eventId in sendEventIds {
                deleteTokenEvent(eventId: eventId)
            }
        }

        recalculateBalance()
        saveState()

        let token = encodeToken(proofs: sendProofs, memo: memo)
        publishHistoryEvent(direction: "out", amount: amountSats, memo: memo ?? "Send ecash token")
        return token
    }

    func receiveToken(tokenString: String) async throws {
        let (tokenProofs, tokenMintURL) = try decodeToken(tokenString)

        // If the token is from a different mint, we need to handle that
        guard tokenMintURL == mintURLString else {
            throw CashuError.mintError(statusCode: 0, message: "Token is from a different mint (\(tokenMintURL))")
        }

        // Swap for fresh proofs (prevents double-spending by sender)
        let totalAmount = tokenProofs.reduce(UInt64(0)) { $0 + $1.amount }
        let outputDenoms = Self.splitAmount(totalAmount)

        let inputProofs = tokenProofs.map {
            CashuProof(amount: $0.amount, keysetId: $0.id, secret: $0.secret, C: $0.C, mintURL: tokenMintURL)
        }

        let freshProofs = try await swap(inputs: inputProofs, outputAmounts: outputDenoms)

        proofs.append(contentsOf: freshProofs)
        recalculateBalance()
        saveState()

        publishTokenEvent(proofs: freshProofs)
        publishHistoryEvent(direction: "in", amount: totalAmount, memo: "Received ecash token")
    }

    func encodeToken(proofs: [CashuProof], memo: String?) -> String {
        let tokenProofs = proofs.map {
            CashuTokenProof(amount: $0.amount, id: $0.keysetId, secret: $0.secret, C: $0.C)
        }
        let token = CashuToken(
            token: [CashuTokenEntry(mint: mintURLString, proofs: tokenProofs)],
            memo: memo,
            unit: "sat"
        )

        guard let jsonData = try? JSONEncoder().encode(token) else { return "" }
        let base64url = jsonData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "cashuA" + base64url
    }

    func decodeToken(_ tokenString: String) throws -> ([CashuTokenProof], String) {
        let trimmed = tokenString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("cashuA") else {
            throw CashuError.invalidTokenPrefix
        }

        var base64 = String(trimmed.dropFirst(6))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Pad to multiple of 4
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: base64) else {
            throw CashuError.tokenDecodingFailed
        }

        let token = try JSONDecoder().decode(CashuToken.self, from: data)
        guard let entry = token.token.first else {
            throw CashuError.invalidToken
        }

        return (entry.proofs, entry.mint)
    }

    // MARK: - Check Proof States (NUT-07)

    func checkProofStates() async throws {
        let unspentProofs = proofs.filter { !$0.isSpent }
        guard !unspentProofs.isEmpty else { return }

        let ys = try unspentProofs.map { proof in
            guard let secretData = Data(hexString: proof.secret) else {
                throw CashuCryptoError.invalidPointData
            }
            let Y = try Self.hashToCurve(secret: secretData)
            return Y.hexString
        }

        let request = CheckStateRequest(Ys: ys)
        let response: CheckStateResponse = try await mintAPIRequest(method: "POST", path: "/v1/checkstate", body: request)

        var removedEventIds: [String] = []
        for state in response.states where state.state == "SPENT" {
            if let index = proofs.firstIndex(where: { proof in
                guard let secretData = Data(hexString: proof.secret) else { return false }
                let Y = try? Self.hashToCurve(secret: secretData)
                return Y?.hexString == state.Y
            }) {
                if let eventId = tokenEventIds[proofs[index].id] {
                    removedEventIds.append(eventId)
                }
                proofs.remove(at: index)
            }
        }

        for eventId in removedEventIds {
            deleteTokenEvent(eventId: eventId)
        }

        recalculateBalance()
        saveState()
    }

    // MARK: - Cashu Crypto (Blind Diffie-Hellman)

    /// hash_to_curve(x): NUT-00 deterministic point from secret
    static func hashToCurve(secret: Data) throws -> Data {
        let msgHash = Data(SHA256.hash(data: secret))

        for counter in UInt32(0)..<UInt32(65536) {
            var preimage = Data([0x02])
            preimage.append(msgHash)
            withUnsafeBytes(of: counter.littleEndian) { preimage.append(contentsOf: $0) }

            let candidateHash = Data(SHA256.hash(data: preimage))
            let compressedCandidate = Data([0x02]) + candidateHash

            // Validate by attempting to parse as a compressed secp256k1 point
            do {
                let _ = try Secp256k1.sumPublicKeys([compressedCandidate])
                return compressedCandidate
            } catch {
                continue
            }
        }
        throw CashuCryptoError.hashToCurveFailed
    }

    /// Create blinded message: B_ = Y + r*G
    static func createBlindedMessage(secret: Data) throws -> (blindedPoint: Data, blindingFactor: Data) {
        let Y = try hashToCurve(secret: secret)

        var rBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &rBytes) == errSecSuccess else {
            throw CashuCryptoError.randomGenerationFailed
        }
        let r = Data(rBytes)

        // B_ = Y + r*G  (addTweakToPublicKey computes: P + tweak*G)
        let B_ = try Secp256k1.addTweakToPubKey(Y, tweak: r)

        return (blindedPoint: B_, blindingFactor: r)
    }

    /// Unblind signature: C = C_ - r*K
    static func unblindSignature(blindedSignature: Data, blindingFactor: Data, mintPubkey: Data) throws -> Data {
        // r*K: multiply the mint's pubkey by the blinding factor
        let rK = try Secp256k1.multiplyPubKey(mintPubkey, scalar: blindingFactor)
        // C = C_ - r*K
        let C = try Secp256k1.subtractPubKeys(blindedSignature, rK)
        return C
    }

    // MARK: - Amount Splitting

    /// Power-of-2 denomination decomposition
    static func splitAmount(_ amount: UInt64) -> [UInt64] {
        var result: [UInt64] = []
        var remaining = amount
        var power: UInt64 = 1

        while remaining > 0 {
            if remaining & 1 == 1 {
                result.append(power)
            }
            remaining >>= 1
            power <<= 1
        }
        return result
    }

    // MARK: - Proof Selection

    func selectProofs(targetAmount: UInt64) -> (selected: [CashuProof], change: UInt64)? {
        let available = proofs.filter { !$0.isSpent }
        let totalAvailable = available.reduce(UInt64(0)) { $0 + $1.amount }
        guard totalAvailable >= targetAmount else { return nil }

        // Sort by amount descending for greedy selection
        let sorted = available.sorted { $0.amount > $1.amount }
        var selected: [CashuProof] = []
        var sum: UInt64 = 0

        for proof in sorted {
            if sum >= targetAmount { break }
            selected.append(proof)
            sum += proof.amount
        }

        guard sum >= targetAmount else { return nil }
        return (selected: selected, change: sum - targetAmount)
    }

    // MARK: - NIP-60 Relay Storage

    /// Publish kind 37375 wallet event (parameterized replaceable)
    func publishWalletEvent() {
        guard let nostrService = getNostrService() else { return }

        let walletContent = NIP60WalletContent(
            mints: [mintURLString],
            relays: ConfigService.shared.config.activeBlastrRelays,
            unit: "sat",
            name: "Haven Cashu Wallet"
        )

        guard let jsonData = try? JSONEncoder().encode(walletContent),
              let json = String(data: jsonData, encoding: .utf8) else { return }

        guard let encrypted = try? encryptToSelf(plaintext: json) else { return }

        let tags: [[String]] = [["d", "cashu"]]
        Task {
            if let event = await nostrService.signEventAsync(kind: 37375, content: encrypted, tags: tags) {
                postEventToPrivateRelay(event)
            }
        }
    }

    /// Publish kind 7375 unspent proof event
    func publishTokenEvent(proofs: [CashuProof]) {
        guard !proofs.isEmpty else { return }
        guard let nostrService = getNostrService() else { return }

        let tokenContent = NIP60TokenContent(
            mint: mintURLString,
            proofs: proofs.map { CashuTokenProof(amount: $0.amount, id: $0.keysetId, secret: $0.secret, C: $0.C) }
        )

        guard let jsonData = try? JSONEncoder().encode(tokenContent),
              let json = String(data: jsonData, encoding: .utf8) else { return }

        guard let encrypted = try? encryptToSelf(plaintext: json) else { return }

        let tags: [[String]] = [["a", "37375:\(getOwnPubkey()):cashu"]]
        Task {
            if let event = await nostrService.signEventAsync(kind: 7375, content: encrypted, tags: tags) {
                postEventToPrivateRelay(event)
                for proof in proofs {
                    tokenEventIds[proof.id] = event.id
                }
                saveState()
            }
        }
    }

    /// Publish kind 7376 history event
    func publishHistoryEvent(direction: String, amount: UInt64, memo: String?) {
        guard let nostrService = getNostrService() else { return }

        let entry = NIP60HistoryEntry(
            direction: direction,
            amount: amount,
            mint: mintURLString,
            unit: "sat",
            createdAt: Int64(Date().timeIntervalSince1970),
            memo: memo
        )

        guard let jsonData = try? JSONEncoder().encode(entry),
              let json = String(data: jsonData, encoding: .utf8) else { return }

        guard let encrypted = try? encryptToSelf(plaintext: json) else { return }

        let tags: [[String]] = [["a", "37375:\(getOwnPubkey()):cashu"]]
        Task {
            if let event = await nostrService.signEventAsync(kind: 7376, content: encrypted, tags: tags) {
                postEventToPrivateRelay(event)
            }
        }
    }

    /// Publish kind 5 deletion for spent token events
    func deleteTokenEvent(eventId: String) {
        guard let nostrService = getNostrService() else { return }

        let tags: [[String]] = [["e", eventId]]
        Task {
            if let event = await nostrService.signEventAsync(kind: 5, content: "spent", tags: tags) {
                postEventToPrivateRelay(event)
            }
        }
    }

    /// Post an event to the Haven private relay endpoint (/private) where NIP-60 wallet data belongs.
    /// NIP-60 events (kinds 37375, 7375, 7376) are encrypted owner-only data and should go to the
    /// private relay, not the outbox relay (root path) which is for public social notes.
    private func postEventToPrivateRelay(_ event: NostrEvent) {
        let config = ConfigService.shared.config
        let privateURL = config.nostrURL + "/private"

        let msg: [Any] = ["EVENT", [
            "id": event.id,
            "pubkey": event.pubkey,
            "created_at": event.created_at,
            "kind": event.kind,
            "tags": event.tags,
            "content": event.content,
            "sig": event.sig
        ] as [String: Any]]

        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }

        guard let url = URL(string: privateURL) else { return }
        let client = WebSocketClient()
        client.isTemporary = true

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { state in
                if state == .connected {
                    client.send(text: str)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        client.disconnect()
                    }
                }
            }
            .store(in: &cancellables)

        client.connect(url: url)
    }

    /// Load wallet state from relay (subscribe to kind 7375 events)
    func loadWalletFromRelays() async {
        let ownPubkey = getOwnPubkey()
        guard !ownPubkey.isEmpty else { return }

        let config = ConfigService.shared.config

        // Query the private relay endpoint first (/private stores NIP-60 wallet data),
        // then fall back to blastr relays
        var relayURLs: [URL] = []
        if let privateURL = URL(string: config.nostrURL + "/private") {
            relayURLs.append(privateURL)
        }
        relayURLs.append(contentsOf: config.activeBlastrRelays.compactMap { URL(string: $0) })
        guard !relayURLs.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        // Fetch kind 7375 events authored by us from each relay
        for relayURL in relayURLs.prefix(3) {
            let client = WebSocketClient()
            client.isTemporary = true

            let subId = "cashu-restore-\(UUID().uuidString.prefix(8))"
            var receivedEvents: [NostrEvent] = []

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                var hasResumed = false

                client.$connectionState
                    .receive(on: DispatchQueue.main)
                    .sink { state in
                        if state == .connected {
                            let filter: [String: Any] = [
                                "kinds": [7375],
                                "authors": [ownPubkey]
                            ]
                            let req: [Any] = ["REQ", subId, filter]
                            if let data = try? JSONSerialization.data(withJSONObject: req),
                               let str = String(data: data, encoding: .utf8) {
                                client.send(text: str)
                            }
                        }
                    }
                    .store(in: &self.cancellables)

                client.messageSubject
                    .receive(on: DispatchQueue.main)
                    .sink { text in
                        guard let data = text.data(using: .utf8),
                              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                              let type = arr.first as? String else { return }

                        if type == "EVENT", arr.count >= 3,
                           let eventDict = arr[2] as? [String: Any],
                           let eventData = try? JSONSerialization.data(withJSONObject: eventDict),
                           let event = try? JSONDecoder().decode(NostrEvent.self, from: eventData) {
                            receivedEvents.append(event)
                        } else if type == "EOSE" {
                            client.disconnect()
                            if !hasResumed {
                                hasResumed = true
                                continuation.resume()
                            }
                        }
                    }
                    .store(in: &self.cancellables)

                client.connect(url: relayURL)

                // Timeout after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    if !hasResumed {
                        hasResumed = true
                        client.disconnect()
                        continuation.resume()
                    }
                }
            }

            // Decrypt and process received token events
            for event in receivedEvents {
                await processTokenEvent(event)
            }
        }

        recalculateBalance()
        saveState()
    }

    private func processTokenEvent(_ event: NostrEvent) async {
        guard let decrypted = try? decryptFromSelf(ciphertext: event.content) else { return }
        guard let data = decrypted.data(using: .utf8),
              let tokenContent = try? JSONDecoder().decode(NIP60TokenContent.self, from: data) else { return }

        for tp in tokenContent.proofs {
            let proof = CashuProof(
                amount: tp.amount,
                keysetId: tp.id,
                secret: tp.secret,
                C: tp.C,
                mintURL: tokenContent.mint
            )
            // Only add if we don't already have it
            if !proofs.contains(where: { $0.secret == proof.secret }) {
                proofs.append(proof)
                tokenEventIds[proof.id] = event.id
            }
        }
    }

    // MARK: - NIP-44 Self-Encryption Helpers

    private func encryptToSelf(plaintext: String) throws -> String {
        let pubkey = getOwnPubkey()
        guard let privkey = getOwnPrivkey(), !pubkey.isEmpty else {
            throw CashuError.noMintConfigured
        }
        return try NIP44Service.encrypt(plaintext: plaintext, recipientPubkey: pubkey, senderPrivkey: privkey)
    }

    private func decryptFromSelf(ciphertext: String) throws -> String {
        let pubkey = getOwnPubkey()
        guard let privkey = getOwnPrivkey(), !pubkey.isEmpty else {
            throw CashuError.noMintConfigured
        }
        return try NIP44Service.decrypt(ciphertext: ciphertext, senderPubkey: pubkey, recipientPrivkey: privkey)
    }

    private func getOwnPubkey() -> String {
        let config = ConfigService.shared.config
        let activeNpub = config.activeAccountNpub.isEmpty ? config.ownerNpub : config.activeAccountNpub
        return Bech32.decode(activeNpub)?.hexString ?? ""
    }

    private func getOwnPrivkey() -> String? {
        let config = ConfigService.shared.config
        if !config.ownerNcryptsec.isEmpty {
            if let password = NIP49Service.getPasswordFromKeychain() {
                return try? config.getDecryptedHexKey(password: password)
            }
            return nil
        }
        return config.ownerHexKey
    }

    @MainActor
    private func getNostrService() -> NostrService? {
        // Access through the app's shared instance
        return NostrService.shared
    }

    // MARK: - Helpers

    private func generateRandomSecret() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        if status != errSecSuccess {
            RelayProcessManager.shared.addLog(
                "CashuService: SecRandomCopyBytes failed with status \(status), using fallback",
                level: "ERROR"
            )
            for i in 0..<32 { bytes[i] = UInt8.random(in: 0...255) }
        }
        return Data(bytes)
    }

    func recalculateBalance() {
        balanceSats = proofs.filter { !$0.isSpent }.reduce(UInt64(0)) { $0 + $1.amount }
    }

    // MARK: - HTTP Client

    private func mintAPIRequest<T: Decodable>(
        method: String,
        path: String,
        body: (any Encodable)? = nil
    ) async throws -> T {
        guard let mintURL = mintURL else { throw CashuError.noMintConfigured }
        guard let url = URL(string: mintURL.absoluteString + path) else {
            throw CashuError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        if let body = body {
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await TLSSkipSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CashuError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw CashuError.mintError(statusCode: httpResponse.statusCode, message: bodyStr)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Persistence (local cache fallback)

    private func stateFileURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Haven", isDirectory: true)
            .appendingPathComponent("cashu_wallet_state.json")
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateFileURL()),
              let state = try? JSONDecoder().decode(CashuWalletState.self, from: data) else { return }
        proofs = state.proofs
        keysets = state.keysets
        activeKeysetId = state.activeKeysetId
        tokenEventIds = state.tokenEventIds
        pendingMintQuotes = state.pendingMintQuotes
        if !state.mintURL.isEmpty {
            mintURL = URL(string: state.mintURL)
        }
        recalculateBalance()
    }

    private func saveState() {
        let state = CashuWalletState(
            proofs: proofs,
            keysets: keysets,
            activeKeysetId: activeKeysetId,
            mintURL: mintURL?.absoluteString ?? "",
            tokenEventIds: tokenEventIds,
            lastSyncTimestamp: Int64(Date().timeIntervalSince1970),
            pendingMintQuotes: pendingMintQuotes
        )
        do {
            let data = try JSONEncoder().encode(state)
            let url = stateFileURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            RelayProcessManager.shared.addLog(
                "CashuService: Failed to save wallet state: \(error.localizedDescription)",
                level: "ERROR"
            )
        }
    }

    // MARK: - Pending Quote Management

    func addPendingQuote(quote: CashuMintQuote, amountSats: UInt64) {
        let pending = PendingMintQuote(
            quoteId: quote.quote,
            amountSats: amountSats,
            bolt11: quote.request,
            createdAt: Int64(Date().timeIntervalSince1970),
            expiresAt: quote.expiry
        )
        guard !pendingMintQuotes.contains(where: { $0.quoteId == pending.quoteId }) else { return }
        pendingMintQuotes.append(pending)
        saveState()
    }

    func removePendingQuote(quoteId: String) {
        pendingMintQuotes.removeAll { $0.quoteId == quoteId }
        saveState()
    }

    /// Checks all pending mint quotes and completes any that have been paid.
    /// Returns the total sats recovered, or 0 if nothing was recovered.
    @discardableResult
    func recoverPendingQuotes() async -> UInt64 {
        guard !isRecovering else { return 0 }
        isRecovering = true
        defer { isRecovering = false }

        let now = Int64(Date().timeIntervalSince1970)
        let expiredIds = pendingMintQuotes.filter { quote in
            if let expiry = quote.expiresAt, expiry > 0 {
                return expiry < now
            }
            return (now - quote.createdAt) > 3600
        }.map { $0.quoteId }

        if !expiredIds.isEmpty {
            pendingMintQuotes.removeAll { expiredIds.contains($0.quoteId) }
            saveState()
        }

        var recoveredSats: UInt64 = 0
        let quotesToCheck = pendingMintQuotes
        for pending in quotesToCheck {
            do {
                let status = try await checkMintQuote(quoteId: pending.quoteId)
                switch status.state {
                case "PAID":
                    try await mintTokens(quoteId: pending.quoteId, amountSats: pending.amountSats)
                    removePendingQuote(quoteId: pending.quoteId)
                    recoveredSats += pending.amountSats
                case "ISSUED":
                    removePendingQuote(quoteId: pending.quoteId)
                case "UNPAID":
                    break
                default:
                    removePendingQuote(quoteId: pending.quoteId)
                }
            } catch {
                // Leave pending for next check; expiry will clean up eventually
            }
        }
        return recoveredSats
    }
}

// MARK: - Data Hex Extensions

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count % 2 == 0 else { return nil }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex

        for _ in 0..<hex.count / 2 {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }
}
