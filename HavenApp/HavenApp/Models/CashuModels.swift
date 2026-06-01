import Foundation

// MARK: - Proof (NUT-00)

struct CashuProof: Codable, Identifiable, Equatable {
    var id: String { "\(keysetId):\(secret)" }
    let amount: UInt64
    let keysetId: String
    let secret: String
    let C: String           // Unblinded signature (hex of 33-byte compressed point)

    // Local-only metadata
    var mintURL: String = ""
    var isSpent: Bool = false

    enum CodingKeys: String, CodingKey {
        case amount, secret, C
        case keysetId = "id"
        case mintURL, isSpent
    }
}

// MARK: - Keyset (NUT-01)

struct CashuKeyset: Codable {
    let id: String
    let unit: String
    let keys: [String: String]  // amount_str -> hex pubkey (33-byte compressed)

    func pubkey(forAmount amount: UInt64) -> String? {
        keys[String(amount)]
    }
}

struct CashuKeysResponse: Codable {
    let keysets: [CashuKeyset]
}

// MARK: - Keyset Info (NUT-02)

struct CashuKeysetInfo: Codable, Identifiable {
    let id: String
    let unit: String
    let active: Bool
}

struct CashuKeysetListResponse: Codable {
    let keysets: [CashuKeysetInfo]
}

// MARK: - Mint Info (NUT-06)

struct CashuMintInfo: Decodable {
    let name: String?
    let version: String?
    let description: String?
    let description_long: String?
    let nuts: [String: CashuNutSupport]?

    // Custom decoder: mints return varied formats for fields like `contact`,
    // `motd`, `pubkey`, etc. We only need a few fields, so decode leniently.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        description_long = try container.decodeIfPresent(String.self, forKey: .description_long)
        nuts = try? container.decodeIfPresent([String: CashuNutSupport].self, forKey: .nuts)
    }

    enum CodingKeys: String, CodingKey {
        case name, version, description, description_long, nuts
    }
}

struct CashuNutSupport: Decodable {
    let methods: [CashuNutMethod]?
    let disabled: Bool?

    // Mints return varied shapes: {"methods":[...],"disabled":false},
    // {"supported":true}, or {"supported":[...]}. Use keyed container.
    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        methods = try? container?.decodeIfPresent([CashuNutMethod].self, forKey: .methods)
        disabled = try? container?.decodeIfPresent(Bool.self, forKey: .disabled)
    }

    enum CodingKeys: String, CodingKey {
        case methods, disabled, supported
    }
}

struct CashuNutMethod: Codable {
    let method: String?
    let unit: String?
    let min_amount: UInt64?
    let max_amount: UInt64?
}

// MARK: - Mint Quote (NUT-04)

struct CashuMintQuote: Codable {
    let quote: String
    let request: String       // Bolt11 invoice to pay
    let state: String         // "UNPAID", "PAID", "ISSUED"
    let expiry: Int64?
}

struct MintQuoteRequest: Encodable {
    let amount: UInt64
    let unit: String
}

struct MintRequest: Encodable {
    let quote: String
    let outputs: [BlindedMessage]
}

struct MintResponse: Codable {
    let signatures: [BlindedSignature]
}

// MARK: - Melt Quote (NUT-05)

struct CashuMeltQuote: Codable {
    let quote: String
    let amount: UInt64
    let fee_reserve: UInt64
    let state: String         // "UNPAID", "PENDING", "PAID"
    let expiry: Int64?
}

struct MeltQuoteRequest: Encodable {
    let request: String       // bolt11 invoice
    let unit: String
}

struct MeltRequest: Encodable {
    let quote: String
    let inputs: [ProofInput]
    let outputs: [BlindedMessage]?
}

struct MeltResponse: Codable {
    let state: String
    let paid: Bool?
    let payment_preimage: String?
    let change: [BlindedSignature]?
}

// MARK: - Swap (NUT-03)

struct SwapRequest: Encodable {
    let inputs: [ProofInput]
    let outputs: [BlindedMessage]
}

struct SwapResponse: Codable {
    let signatures: [BlindedSignature]
}

// MARK: - Check State (NUT-07)

struct CheckStateRequest: Encodable {
    let Ys: [String]
}

struct ProofState: Codable {
    let Y: String
    let state: String         // "UNSPENT", "PENDING", "SPENT"
}

struct CheckStateResponse: Codable {
    let states: [ProofState]
}

// MARK: - Blinded Message & Signature

struct BlindedMessage: Codable {
    let amount: UInt64
    let id: String            // Keyset ID
    let B_: String            // Hex of blinded point (33 bytes compressed)
}

struct BlindedSignature: Codable {
    let amount: UInt64
    let id: String            // Keyset ID
    let C_: String            // Hex of blind signature (33 bytes compressed)
}

struct ProofInput: Encodable {
    let amount: UInt64
    let id: String            // Keyset ID
    let secret: String
    let C: String
}

// MARK: - Token Serialization (NUT-00)

struct CashuToken: Codable {
    let token: [CashuTokenEntry]
    let memo: String?
    let unit: String?
}

struct CashuTokenEntry: Codable {
    let mint: String
    let proofs: [CashuTokenProof]
}

struct CashuTokenProof: Codable {
    let amount: UInt64
    let id: String
    let secret: String
    let C: String
}

// MARK: - NIP-60 Wallet Event Models

struct NIP60WalletContent: Codable {
    let mints: [String]
    let relays: [String]?
    let unit: String?
    let name: String?
}

struct NIP60TokenContent: Codable {
    let mint: String
    let proofs: [CashuTokenProof]
}

struct NIP60HistoryEntry: Codable {
    let direction: String     // "in" or "out"
    let amount: UInt64
    let mint: String
    let unit: String?
    let createdAt: Int64
    let memo: String?

    enum CodingKeys: String, CodingKey {
        case direction, amount, mint, unit
        case createdAt = "created_at"
        case memo
    }
}

// MARK: - Local Wallet State (cache)

struct CashuWalletState: Codable {
    var proofs: [CashuProof]
    var keysets: [String: CashuKeyset]
    var activeKeysetId: String
    var mintURL: String
    var tokenEventIds: [String: String]  // proofId -> nostr event id (for deletion)
    var lastSyncTimestamp: Int64
    var pendingMintQuotes: [PendingMintQuote]

    init(proofs: [CashuProof], keysets: [String: CashuKeyset], activeKeysetId: String,
         mintURL: String, tokenEventIds: [String: String], lastSyncTimestamp: Int64,
         pendingMintQuotes: [PendingMintQuote] = []) {
        self.proofs = proofs
        self.keysets = keysets
        self.activeKeysetId = activeKeysetId
        self.mintURL = mintURL
        self.tokenEventIds = tokenEventIds
        self.lastSyncTimestamp = lastSyncTimestamp
        self.pendingMintQuotes = pendingMintQuotes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        proofs = try container.decode([CashuProof].self, forKey: .proofs)
        keysets = try container.decode([String: CashuKeyset].self, forKey: .keysets)
        activeKeysetId = try container.decode(String.self, forKey: .activeKeysetId)
        mintURL = try container.decode(String.self, forKey: .mintURL)
        tokenEventIds = try container.decode([String: String].self, forKey: .tokenEventIds)
        lastSyncTimestamp = try container.decode(Int64.self, forKey: .lastSyncTimestamp)
        pendingMintQuotes = try container.decodeIfPresent([PendingMintQuote].self, forKey: .pendingMintQuotes) ?? []
    }
}

// MARK: - Pending Mint Quote (for recovery)

struct PendingMintQuote: Codable, Identifiable, Equatable {
    var id: String { quoteId }
    let quoteId: String
    let amountSats: UInt64
    let bolt11: String
    let createdAt: Int64
    let expiresAt: Int64?
}

// MARK: - Cashu Errors

enum CashuError: Error, LocalizedError {
    case noMintConfigured
    case invalidURL
    case invalidResponse
    case mintError(statusCode: Int, message: String)
    case noActiveKeyset
    case insufficientBalance
    case invalidToken
    case invalidTokenPrefix
    case tokenDecodingFailed
    case proofCreationFailed

    var errorDescription: String? {
        switch self {
        case .noMintConfigured: return "No Cashu mint configured"
        case .invalidURL: return "Invalid mint URL"
        case .invalidResponse: return "Invalid response from mint"
        case .mintError(let code, let msg): return "Mint error (\(code)): \(msg)"
        case .noActiveKeyset: return "No active keyset from mint"
        case .insufficientBalance: return "Insufficient ecash balance"
        case .invalidToken: return "Invalid Cashu token"
        case .invalidTokenPrefix: return "Token must start with cashuA"
        case .tokenDecodingFailed: return "Failed to decode Cashu token"
        case .proofCreationFailed: return "Failed to create proofs"
        }
    }
}

enum CashuCryptoError: Error, LocalizedError {
    case hashToCurveFailed
    case randomGenerationFailed
    case invalidPointData
    case blindingFailed
    case unblindingFailed

    var errorDescription: String? {
        switch self {
        case .hashToCurveFailed: return "Failed to hash to curve point"
        case .randomGenerationFailed: return "Failed to generate random bytes"
        case .invalidPointData: return "Invalid elliptic curve point data"
        case .blindingFailed: return "Blinding operation failed"
        case .unblindingFailed: return "Unblinding operation failed"
        }
    }
}
