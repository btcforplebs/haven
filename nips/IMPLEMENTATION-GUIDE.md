# Implementation Guide: NIP OAuth Identity Backup

This guide helps Nostr client developers implement the OAuth Identity Backup NIP.

## Quick Start Checklist

### Phase 1: Basic Implementation (1-2 days)

- [ ] **Add OAuth provider SDK**
  - iOS: `import AuthenticationServices` (built-in)
  - Android: Google Sign In SDK

- [ ] **Implement key derivation**
  - [ ] HMAC-SHA256 salt calculation
  - [ ] Password string concatenation
  - [ ] Verify against test vectors

- [ ] **Add NIP-49 encryption**
  - [ ] Use existing NIP-49 library or implement spec
  - [ ] Encrypt: `nsec → ncryptsec`
  - [ ] Decrypt: `ncryptsec → nsec`

- [ ] **Implement cloud keychain storage**
  - iOS: Use `kSecClass` API with `kSecAttrSynchronizable = true`
  - Android: Use Credential Manager / Smart Lock
  - [ ] Use universal namespace: `"com.nostr.identity.backup"`
  - [ ] Store with npub as account identifier

### Phase 2: User Flows (2-3 days)

- [ ] **Sign in flow**
  - [ ] "Sign in with Apple/Google" button
  - [ ] OAuth authentication
  - [ ] Query cloud keychain for existing backups
  - [ ] If found: PIN entry → decrypt → restore
  - [ ] If not found: create new or import existing

- [ ] **Backup creation**
  - [ ] Generate new keypair OR import existing nsec
  - [ ] PIN entry (4-8 digits with validation)
  - [ ] PIN confirmation
  - [ ] Encrypt and store in cloud keychain
  - [ ] Success confirmation

- [ ] **Account discovery**
  - [ ] List all backups in cloud keychain
  - [ ] Show npub prefixes for selection
  - [ ] Handle multiple accounts gracefully

### Phase 3: Security & UX (1-2 days)

- [ ] **PIN validation**
  - [ ] Enforce 4-8 digit requirement
  - [ ] Reject sequential patterns (1234, 0000)
  - [ ] Local rate limiting (exponential backoff)

- [ ] **Error handling**
  - [ ] User cancels OAuth flow
  - [ ] Cloud sync disabled
  - [ ] Incorrect PIN (with retry limit)
  - [ ] Backup corruption

- [ ] **User education**
  - [ ] Explain trade-offs (info sheets)
  - [ ] Warn about unknown key history when importing
  - [ ] Security comparison with other methods

### Phase 4: Testing (1 day)

- [ ] **Unit tests**
  - [ ] Key derivation matches test vectors
  - [ ] Encryption/decryption round-trip
  - [ ] Edge cases (empty strings, max lengths)

- [ ] **Integration tests**
  - [ ] Full backup and restore flow
  - [ ] Multi-device sync (if possible)
  - [ ] Account switching

- [ ] **Cross-app testing**
  - [ ] Create backup in your app
  - [ ] Restore in reference implementation (Nostr Vault)
  - [ ] Verify nsec matches

---

## Implementation Details

### 1. Key Derivation (Swift)

```swift
import CryptoKit

struct IdentityBackup {
    static let saltContext = "nostr-identity-v1"

    static func derivePassword(
        provider: String,  // "apple", "google", etc.
        userID: String,    // OAuth user identifier
        pin: String        // 4-8 digit PIN
    ) throws -> String {
        // Validate PIN
        guard pin.count >= 4 && pin.count <= 8 else {
            throw BackupError.invalidPin
        }
        guard pin.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw BackupError.invalidPin
        }

        // Calculate salt
        let message = "\(provider):\(userID)"
        let key = SymmetricKey(data: Data(saltContext.utf8))
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: key
        )
        let salt = Data(mac).map { String(format: "%02x", $0) }.joined()

        // Derive password
        return "\(pin)-\(provider)-\(userID)-\(salt)"
    }
}
```

### 2. Cloud Keychain Storage (iOS) - Privacy-Preserving Design

**IMPORTANT:** Store all backups in a single keychain entry to prevent Apple from seeing individual npubs.

```swift
import Security

struct CloudKeychain {
    static let service = "com.nostr.identity.backup"
    static let account = "nostr-identities" // Constant - hides individual npubs

    struct BackupItem: Codable {
        let npub: String
        let ncryptsec: String
        let createdAt: Date
    }

    private struct Container: Codable {
        var backups: [BackupItem]
    }

    static func store(npub: String, ncryptsec: String) throws {
        // Load existing container (or create new)
        var container: Container
        do {
            container = try loadContainer()
        } catch {
            container = Container(backups: [])
        }

        // Update or add backup
        container.backups.removeAll { $0.npub == npub }
        container.backups.append(BackupItem(
            npub: npub,
            ncryptsec: ncryptsec,
            createdAt: Date()
        ))

        // Save container
        try saveContainer(container)
    }

    static func load(npub: String) throws -> String {
        let container = try loadContainer()
        guard let backup = container.backups.first(where: { $0.npub == npub }) else {
            throw KeychainError.notFound
        }
        return backup.ncryptsec
    }

    static func listAll() throws -> [BackupItem] {
        do {
            return try loadContainer().backups
        } catch {
            return []
        }
    }

    private static func loadContainer() throws -> Container {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data else {
            throw KeychainError.notFound
        }

        return try JSONDecoder().decode(Container.self, from: data)
    }

    private static func saveContainer(_ container: Container) throws {
        let data = try JSONEncoder().encode(container)

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrSynchronizable as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel as String: "Nostr Identity Backups"
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status)
        }
    }
}
```

### 3. Sign In Flow (iOS)

```swift
import AuthenticationServices

class IdentityManager {
    func signInWithApple(presenting: UIViewController) async throws -> String {
        // Trigger Apple Sign In
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        let delegate = AuthDelegate()
        controller.delegate = delegate
        controller.presentationContextProvider = delegate
        controller.performRequests()

        // Wait for result
        let credential = try await delegate.result
        let appleUserID = credential.user

        // Check for existing backups
        let existingBackups = try CloudKeychain.listAll()

        if existingBackups.isEmpty {
            // No backups found - create new or import
            return try await createNewIdentity(appleUserID: appleUserID)
        } else {
            // Found backups - restore
            return try await restoreIdentity(
                appleUserID: appleUserID,
                npubs: existingBackups
            )
        }
    }

    private func restoreIdentity(
        appleUserID: String,
        npubs: [String]
    ) async throws -> String {
        // Show account picker if multiple
        let selectedNpub = npubs.count == 1 ? npubs[0] : try await showAccountPicker(npubs)

        // Prompt for PIN
        let pin = try await promptForPIN()

        // Derive password
        let password = try IdentityBackup.derivePassword(
            provider: "apple",
            userID: appleUserID,
            pin: pin
        )

        // Load and decrypt
        let ncryptsec = try CloudKeychain.load(npub: selectedNpub)
        let nsec = try NIP49.decrypt(ncryptsec: ncryptsec, password: password)

        return nsec
    }
}
```

---

## Platform-Specific Notes

### iOS/macOS

**Capabilities Required:**
- Sign in with Apple
- iCloud → Key-value storage

**Entitlements:**
```xml
<key>com.apple.developer.applesignin</key>
<array>
    <string>Default</string>
</array>
<key>com.apple.developer.ubiquity-kvstore-identifier</key>
<string>$(TeamIdentifierPrefix)$(CFBundleIdentifier)</string>
```

**Testing:**
- Requires paid Apple Developer account ($99/year)
- Test on physical device (Simulator doesn't sync iCloud)
- Use TestFlight for multi-device testing

### Android

**Dependencies:**
```gradle
implementation 'com.google.android.gms:play-services-auth:20.7.0'
implementation 'androidx.credentials:credentials:1.2.0'
```

**Testing:**
- Test on physical device (emulator may not have Google Play Services)
- Enable "Smart Lock for Passwords" in device settings

---

## Migration from Existing Schemes

If your app already has an app-specific backup system:

### Step 1: Detect Legacy Backups

```swift
let legacyService = "com.yourapp.backup"  // Old namespace
let hasLegacy = try CloudKeychain.hasBackup(service: legacyService)
```

### Step 2: Prompt User to Migrate

```
"We've updated our backup system for better cross-app compatibility.
Would you like to migrate your backup to the new universal format?"

[Migrate Now]  [Ask Me Later]
```

### Step 3: Re-encrypt with New Standard

```swift
// Load from legacy
let oldNcryptsec = try CloudKeychain.load(service: legacyService, npub: npub)
let nsec = try NIP49.decrypt(ncryptsec: oldNcryptsec, password: oldPassword)

// Store with new standard
let newPassword = try IdentityBackup.derivePassword(
    provider: "apple",
    userID: appleUserID,
    pin: pin
)
let newNcryptsec = try NIP49.encrypt(nsec: nsec, password: newPassword)
try CloudKeychain.store(
    service: "com.nostr.identity.backup",  // Universal
    npub: npub,
    ncryptsec: newNcryptsec
)

// Delete legacy
try CloudKeychain.delete(service: legacyService, npub: npub)
```

---

## Troubleshooting

### Common Issues

**"Cloud sync is disabled"**
- Prompt user to enable iCloud in Settings
- iOS: Settings → [Name] → iCloud → iCloud Drive
- Android: Settings → Google → Backup

**"Incorrect PIN" loops**
- Implement exponential backoff (5 attempts → 1min wait, 10 attempts → 10min)
- Consider adding "Forgot PIN?" flow (requires generating new identity)

**"Multiple accounts found but user only has one"**
- Check for orphaned backups from deleted accounts
- Provide UI to delete unused backups

**Cross-app restore fails**
- Verify both apps use exact same key derivation
- Check test vectors for byte-for-byte match
- Ensure both use same provider (Apple vs Google)

---

## Resources

- [NIP-49 Reference Implementation](https://github.com/nostr-protocol/nips/blob/master/49.md)
- [Apple Sign In Docs](https://developer.apple.com/documentation/sign_in_with_apple)
- [Google Sign In Docs](https://developers.google.com/identity/sign-in/web/sign-in)
- [Test Vectors](./test-vectors.md)
- [Reference Implementation: Nostr Vault](../HavenApp/HavenApp/Services/)

---

## Support

Questions or issues implementing this NIP?

- Open an issue: [GitHub Issues](https://github.com/your-repo/issues)
- Nostr: Contact the authors
- Matrix: #nostr-dev:matrix.org

---

## Timeline

**Week 1-2:** Implement core (key derivation, encryption, storage)
**Week 3:** Implement UI flows (sign in, backup, restore)
**Week 4:** Testing and refinement
**Week 5+:** Coordinate with other app developers for cross-app testing

Total estimated time: **1-2 months** for full production-ready implementation.
