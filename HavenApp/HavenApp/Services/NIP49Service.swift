import Foundation
import CryptoKit
import CommonCrypto
import Security

/// NIP-49: Private Key Encryption
/// Provides password-protected encryption of Nostr private keys
/// Reference: https://nips.nostr.com/49
///
/// Encryption/decryption is handled by Go FFI bridge (scrypt + XChaCha20-Poly1305)
/// for full NIP-49 spec compliance. A legacy AES-GCM fallback is retained for
/// decrypting any ncryptsec values that may have been created by the old Swift implementation.
struct NIP49Service {

    // MARK: - Error Types
    enum NIP49Error: LocalizedError {
        case invalidEncrypted
        case decryptionFailed
        case invalidPassword
        case encodingFailed
        case decodingFailed

        var errorDescription: String? {
            switch self {
            case .invalidEncrypted:
                return "Invalid encrypted key format"
            case .decryptionFailed:
                return "Failed to decrypt key with this password"
            case .invalidPassword:
                return "Password is required"
            case .encodingFailed:
                return "Failed to encode encrypted key"
            case .decodingFailed:
                return "Failed to decode encrypted key"
            }
        }
    }

    // MARK: - Encryption (nsec → ncryptsec)

    /// Encrypts a private key (nsec) with a password to create ncryptsec format.
    /// Uses Go FFI bridge for NIP-49 spec-compliant scrypt + XChaCha20-Poly1305.
    static func encrypt(nsec: String, password: String) throws -> String {
        guard !password.isEmpty else { throw NIP49Error.invalidPassword }

        let hexKey = try decodeNsec(nsec)

        guard let resultCStr = EncryptNIP49C(
            UnsafeMutablePointer(mutating: (hexKey as NSString).utf8String),
            UnsafeMutablePointer(mutating: (password as NSString).utf8String)
        ) else {
            throw NIP49Error.encodingFailed
        }

        let result = String(cString: resultCStr)
        free(resultCStr)
        return result
    }

    // MARK: - Decryption (ncryptsec → nsec)

    /// Decrypts an ncryptsec key with a password to retrieve the private key.
    /// Tries NIP-49 spec-compliant Go FFI first, then falls back to the legacy
    /// AES-GCM method for backward compatibility with any existing stored values.
    static func decrypt(ncryptsec: String, password: String) throws -> String {
        guard !password.isEmpty else { throw NIP49Error.invalidPassword }

        // Try spec-compliant Go FFI first
        if let resultCStr = DecryptNIP49C(
            UnsafeMutablePointer(mutating: (ncryptsec as NSString).utf8String),
            UnsafeMutablePointer(mutating: (password as NSString).utf8String)
        ) {
            let hexKey = String(cString: resultCStr)
            free(resultCStr)

            guard let nsec = Bech32.encode(hrp: "nsec", data: Data(hex: hexKey) ?? Data()) else {
                throw NIP49Error.encodingFailed
            }
            return nsec
        }

        // Fallback: try legacy AES-GCM format for backward compatibility
        return try decryptLegacy(ncryptsec: ncryptsec, password: password)
    }

    // MARK: - Legacy Decryption (backward compatibility)

    /// Decrypts ncryptsec values created by the old PBKDF2 + AES-GCM implementation.
    private static func decryptLegacy(ncryptsec: String, password: String) throws -> String {
        guard let decoded = Bech32.decode(ncryptsec.lowercased()),
              decoded.hrp == "ncryptsec" else {
            throw NIP49Error.invalidEncrypted
        }

        let payload = decoded.data
        guard payload.count > 57 else { throw NIP49Error.invalidEncrypted }

        let version = payload[0]
        guard version == 1 else { throw NIP49Error.invalidEncrypted }

        let salt = payload[1..<17]
        let nonce = payload[17..<41]
        let ciphertext = payload[41..<(payload.count - 16)]
        let tag = payload[(payload.count - 16)...]

        let passwordData = password.data(using: .utf8) ?? Data()
        let derivedKey = PBKDF2.derive(
            password: passwordData,
            salt: Data(salt),
            iterations: 262144,
            keyLength: 32
        )

        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: try AES.GCM.Nonce(data: Data(nonce)),
                ciphertext: Data(ciphertext),
                tag: Data(tag)
            )
            let decrypted = try AES.GCM.open(sealedBox, using: SymmetricKey(data: derivedKey))

            guard let nsec = Bech32.encode(hrp: "nsec", data: decrypted) else {
                throw NIP49Error.encodingFailed
            }
            return nsec
        } catch {
            #if DEBUG
            print("NIP49Service: Legacy AES-GCM decrypt also failed: \(error)")
            #endif
            throw NIP49Error.decryptionFailed
        }
    }

    // MARK: - Utilities

    /// Checks if a string is in ncryptsec format
    static func isNcryptsec(_ value: String) -> Bool {
        guard let decoded = Bech32.decode(value.lowercased()) else { return false }
        return decoded.hrp == "ncryptsec"
    }

    /// Decodes nsec to hex private key
    private static func decodeNsec(_ nsec: String) throws -> String {
        guard let decoded = Bech32.decode(nsec.lowercased()),
              decoded.hrp == "nsec" else {
            throw NIP49Error.decodingFailed
        }
        return decoded.data.hex
    }

    // MARK: - Keychain Storage for Password

    /// Keychain service identifier
    private static let keychainService = "com.havenapp.nip49"
    private static let keychainAccount = "owner-key-password"

    /// Stores the NIP-49 password securely in Keychain
    /// - Parameter password: The password to store
    /// - Returns: True if storage was successful
    static func storePasswordInKeychain(_ password: String) -> Bool {
        guard let passwordData = password.data(using: .utf8) else { return false }

        // First, try to delete any existing item
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add the new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)

        if status == errSecSuccess {
            #if DEBUG
            print("NIP49Service: Password stored successfully in Keychain")
            #endif
            return true
        } else {
            #if DEBUG
            print("NIP49Service: Failed to store password in Keychain: \(status)")
            #endif
            return false
        }
    }

    /// Retrieves the NIP-49 password from Keychain
    /// - Returns: The stored password, or nil if not found
    static func getPasswordFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let passwordData = result as? Data {
            return String(data: passwordData, encoding: .utf8)
        } else if status == errSecItemNotFound {
            #if DEBUG
            print("NIP49Service: No password found in Keychain")
            #endif
        } else {
            #if DEBUG
            print("NIP49Service: Error retrieving password from Keychain: \(status)")
            #endif
        }

        return nil
    }

    /// Deletes the NIP-49 password from Keychain
    /// - Returns: True if deletion was successful
    static func deletePasswordFromKeychain() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]

        let status = SecItemDelete(query as CFDictionary)

        if status == errSecSuccess || status == errSecItemNotFound {
            #if DEBUG
            print("NIP49Service: Password deleted from Keychain")
            #endif
            return true
        } else {
            #if DEBUG
            print("NIP49Service: Failed to delete password from Keychain: \(status)")
            #endif
            return false
        }
    }

    /// Checks if a password is stored in Keychain
    /// - Returns: True if password exists
    static func hasStoredPassword() -> Bool {
        return getPasswordFromKeychain() != nil
    }

    // MARK: - Per-Account Keychain Storage (whitelisted accounts)

    /// Returns the Keychain account identifier namespaced by npub
    private static func keychainAccountId(forNpub npub: String) -> String {
        return "account-key-password-\(npub)"
    }

    /// Stores the NIP-49 password for a specific npub in Keychain
    @discardableResult
    static func storePasswordInKeychain(_ password: String, forNpub npub: String) -> Bool {
        guard let passwordData = password.data(using: .utf8) else { return false }
        let accountId = keychainAccountId(forNpub: npub)

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountId
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountId,
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        #if DEBUG
        print("NIP49Service: Store password for npub \(npub.prefix(12))... status=\(status == errSecSuccess ? "ok" : "\(status)")")
        #endif
        return status == errSecSuccess
    }

    /// Retrieves the NIP-49 password for a specific npub from Keychain
    static func getPasswordFromKeychain(forNpub npub: String) -> String? {
        let accountId = keychainAccountId(forNpub: npub)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let passwordData = result as? Data {
            return String(data: passwordData, encoding: .utf8)
        }
        return nil
    }

    /// Removes the stored password for a specific npub from Keychain
    @discardableResult
    static func deletePasswordFromKeychain(forNpub npub: String) -> Bool {
        let accountId = keychainAccountId(forNpub: npub)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountId
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// MARK: - Legacy PBKDF2 Helper (retained for backward-compatible decryption)

private struct PBKDF2 {
    static func derive(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data {
        var result = [UInt8](repeating: 0, count: keyLength)

        let passwordBytes = [UInt8](password)
        let saltBytes = [UInt8](salt)

        CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordBytes,
            passwordBytes.count,
            saltBytes,
            saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            UInt32(iterations),
            &result,
            result.count
        )

        return Data(result)
    }
}

// MARK: - Data Extensions

extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hex: String) {
        self.init(capacity: hex.count / 2)
        let regex = try! NSRegularExpression(pattern: "[0-9a-f]{2}", options: .caseInsensitive)
        let nsHex = hex as NSString
        let range = NSRange(location: 0, length: nsHex.length)

        for match in regex.matches(in: hex, range: range) {
            let byteStr = nsHex.substring(with: match.range)
            if let num = UInt8(byteStr, radix: 16) {
                append(num)
            } else {
                return nil
            }
        }
    }
}
