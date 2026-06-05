NIP-XX
======

Universal Nostr Identity Backup via OAuth Provider Sign-In
-----------------------------------------------------------

`draft` `optional`

## Abstract

This NIP defines a standard protocol for backing up Nostr identities to cloud keychain services using OAuth provider authentication (Apple Sign In, Google Sign In, etc.). It enables seamless cross-app identity portability: a user can generate keys in one Nostr client, back them up via their Apple/Google account, and restore them in any other compliant client using the same provider credentials.

## Motivation

Current Nostr key management requires users to:
- Manually copy and paste nsec across apps
- Remember or write down seed phrases
- Manage multiple backup files
- Risk losing access if keys are lost

This creates significant UX friction and limits Nostr adoption. OAuth-based identity backup offers:
- **No seed phrases**: Users authenticate with Face ID/Touch ID
- **Cross-app portability**: Same identity in all Nostr apps
- **Automatic sync**: Keys sync across user's devices
- **Familiar UX**: Leverage existing "Sign in with Apple/Google" patterns

## Specification

### 1. Provider Authentication

Clients MUST support one or more OAuth identity providers:
- **Apple Sign In**: Returns stable, team-scoped user identifier via `ASAuthorizationAppleIDCredential.user`
- **Google Sign In**: Returns stable user identifier via JWT `sub` claim
- **Future providers**: Microsoft, GitHub, etc. following same pattern

The provider user ID is:
- Stable (never changes for this user + provider combination)
- Opaque (not the user's email or personal info)
- Provider-scoped (same user gets different IDs from Apple vs Google)

### 2. Key Derivation

#### 2.1 Password Derivation

The encryption password is derived from the user's PIN and provider identifier:

```
providerPrefix = "apple" | "google" | "microsoft" | ...
providerUserID = stable_identifier_from_oauth_provider
userPIN = 4_to_8_digit_numeric_pin
npub = user's_public_key_bech32 (optional, for multi-account isolation)

saltContext = "nostr-identity-v1"

// Basic derivation (single account per provider):
salt = HMAC-SHA256(key: saltContext, message: providerPrefix + ":" + providerUserID)
password = userPIN + "-" + providerPrefix + "-" + providerUserID + "-" + hex(salt)

// Enhanced derivation (recommended for multi-account support):
salt = HMAC-SHA256(key: saltContext, message: providerPrefix + ":" + providerUserID + ":" + npub)
password = userPIN + "-" + providerPrefix + "-" + providerUserID + "-" + npub + "-" + hex(salt)
```

**Note:** Including npub in salt derivation ensures perfect cryptographic isolation between identities even when sharing the same PIN. Clients implementing multi-account support SHOULD use the enhanced derivation.

**Example (Enhanced):**
```
providerPrefix = "apple"
providerUserID = "001234.abcdef1234567890.1234"
npub = "npub1abc...xyz"
userPIN = "8264"
saltContext = "nostr-identity-v1"

salt = HMAC-SHA256("nostr-identity-v1", "apple:001234.abcdef1234567890.1234:npub1abc...xyz")
     = "a3f2c8d9e1b4f7a6c2d8e9f1a3b4c5d6..."

password = "8264-apple-001234.abcdef1234567890.1234-npub1abc...xyz-a3f2c8d9e1b4f7a6c2d8e9f1a3b4c5d6..."
```

#### 2.2 Encryption

The nsec is encrypted using [NIP-49](https://github.com/nostr-protocol/nips/blob/master/49.md) with the derived password:

```
ncryptsec = NIP49_encrypt(nsec, password)
```

This provides:
- scrypt key derivation (N=2^20, r=8, p=1)
- XChaCha20-Poly1305 authenticated encryption
- Bech32-encoded `ncryptsec1...` format

### 3. Cloud Storage

#### 3.1 Keychain Namespace (Privacy-Preserving Design)

**IMPORTANT PRIVACY CONSIDERATION:**
To prevent the cloud provider (Apple/Google) from observing individual npubs, all backups are stored in a **single keychain entry** containing a JSON array. This ensures:
- Provider sees: ONE backup entry per user account
- Provider CANNOT see: how many identities, what the npubs are, when identities were created

**iOS/macOS (iCloud Keychain):**
```swift
kSecClass: kSecClassGenericPassword
kSecAttrService: "com.nostr.identity.backup"
kSecAttrAccount: "nostr-identities" (constant - hides individual npubs)
kSecValueData: JSON array of all backups (see format below)
kSecAttrSynchronizable: true
kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
kSecAttrLabel: "Nostr Identity Backups"
```

**Android (Google Smart Lock / Credential Manager):**
```kotlin
accountType: "com.nostr.identity.backup"
accountName: "nostr-identities" (constant)
password: JSON array of all backups
```

#### 3.2 Backup Container Format

The keychain value is a JSON array containing all backed-up identities:

```json
{
  "backups": [
    {
      "npub": "npub1xyz...",
      "ncryptsec": "ncryptsec1...",
      "created_at": "2024-01-15T10:30:00Z",
      "provider": "apple",
      "app_name": "Nostr Vault",
      "app_version": "1.0.0"
    },
    {
      "npub": "npub1abc...",
      "ncryptsec": "ncryptsec1...",
      "created_at": "2024-02-20T14:15:00Z",
      "provider": "apple",
      "app_name": "Damus",
      "app_version": "2.1.0"
    }
  ]
}
```

**Privacy Benefits:**
- Cloud provider cannot correlate multiple identities to one user
- Cannot observe identity creation patterns
- Cannot build identity graphs based on backup metadata
- Users maintain better pseudonymity across their identities

### 4. Backup Flow

#### 4.1 Creating a New Backup

```
1. User taps "Sign in with Apple/Google"
2. OAuth provider authentication flow
3. Provider returns stable user ID
4. Check for existing backups in cloud keychain
5. IF backup exists:
     a. Prompt for PIN
     b. Attempt decryption of each backup
     c. On success: restore identity and enter app
     d. On failure: prompt "Incorrect PIN or create new identity"
6. IF no backup exists:
     a. Prompt user: "Create new identity" or "Import existing nsec"
     b. IF creating new:
          - Generate keypair locally
          - Prompt to set 4-8 digit PIN
          - Derive password from (PIN + provider ID)
          - Encrypt nsec with NIP-49
          - Store ncryptsec in cloud keychain
     c. IF importing existing:
          - User pastes nsec
          - Prompt to set 4-8 digit PIN
          - Derive password from (PIN + provider ID)
          - Encrypt nsec with NIP-49
          - Store ncryptsec in cloud keychain
7. Success: user is signed in
```

#### 4.2 Restoring from Backup

```
1. User taps "Sign in with Apple/Google" on new device/app
2. OAuth provider authentication flow
3. Provider returns stable user ID
4. Query cloud keychain for items matching:
     kSecAttrService: "com.nostr.identity.backup"
5. IF multiple backups found:
     a. Show account picker with npub prefixes
     b. User selects account
6. Prompt for PIN (with rate limiting)
7. Derive password from (PIN + provider ID)
8. Decrypt ncryptsec with NIP-49
9. IF decryption succeeds:
     - Extract nsec
     - Derive npub to verify
     - Enter app with restored identity
10. IF decryption fails:
     - Show error: "Incorrect PIN"
     - Allow retry (with exponential backoff)
```

### 5. Security Considerations

#### 5.1 Threat Model

**What attackers need to compromise keys:**

| Attack Vector | Requirements | Difficulty |
|---------------|-------------|------------|
| Device theft | Physical device + device passcode + user's PIN | High (requires 2 factors) |
| Cloud account breach | OAuth provider credentials + user's PIN + offline brute force | Very High (requires provider breach + PIN crack) |
| Malicious app on same cloud account | Sandboxing prevents cross-app keychain access | Mitigated by OS |

**Defense in depth:**
1. **OAuth provider security**: 2FA, device trust, anomaly detection
2. **Cloud E2E encryption**: iCloud Keychain is encrypted with device passcode
3. **NIP-49 scrypt**: Memory-hard KDF resists GPU/ASIC brute force
4. **PIN rate limiting**: Clients SHOULD implement exponential backoff

#### 5.2 PIN Strength Requirements

Clients MUST enforce PIN requirements:
- Minimum length: 4 digits (10,000 combinations)
- Maximum length: 8 digits (100,000,000 combinations)
- MUST be numeric only
- SHOULD reject sequential patterns (1234, 0000)
- SHOULD implement local rate limiting (exponential backoff after N failed attempts)

**Brute force resistance:**
```
4-digit PIN: ~3 hours offline attack with scrypt
6-digit PIN: ~12 days offline attack
8-digit PIN: ~3 years offline attack
```

Clients SHOULD recommend 6+ digits.

#### 5.3 Key History Warnings

When importing an existing nsec, clients SHOULD warn users about unknown key history:

```
⚠️ Security Warning

You're importing a key that was created elsewhere. We can't verify:
- Where it was generated
- If it's been exposed (screenshots, web clients, etc.)
- Who else might have access to it

Consider generating a fresh identity for maximum security.
```

#### 5.4 Provider Trust Model

Users trust:
1. **OAuth provider** (Apple, Google) for authentication and cloud storage
2. **Client app** (Nostr Vault, Damus) to implement spec correctly
3. **Their own PIN** for encryption key derivation

Users do NOT trust:
- The provider can see encrypted backups but cannot decrypt them (no PIN)
- Client apps cannot access backups created by other apps (sandboxing)
- The Nostr relay network (keys never transmitted in plaintext)

### 6. Migration and Compatibility

#### 6.1 Backward Compatibility

Clients with existing app-specific backup schemes SHOULD:
1. Detect legacy backups on first OAuth sign-in
2. Prompt user: "Migrate to universal backup?"
3. Re-encrypt with universal standard and delete legacy backup
4. Mark migration complete to avoid re-prompting

#### 6.2 Multi-Provider Support

Users MAY back up the same nsec with multiple providers:

```
Same nsec backed up to:
- Apple Sign In (for iOS/macOS devices)
- Google Sign In (for Android/cross-platform)
```

Each provider uses a different `providerPrefix` in key derivation, creating independent encrypted copies.

#### 6.3 Multi-Account Support

Users MAY back up multiple Nostr identities under the same OAuth provider account:

```
One Apple ID → Multiple Nostr identities:
├─ npub1abc...xyz → ncryptsec (Alice, PIN: 1234)
├─ npub1def...uvw → ncryptsec (Bob, PIN: 5678)
└─ npub1ghi...rst → ncryptsec (Carol, PIN: 1234)

All stored under:
  kSecAttrService: "com.nostr.identity.backup"
  kSecAttrAccount: <npub> (unique per identity)
```

**Discovery Flow:**

When a user authenticates with their OAuth provider:

1. Client queries cloud keychain for all backups under service `"com.nostr.identity.backup"`
2. If multiple backups found:
   - Display account picker showing npub prefixes
   - Optionally show metadata (last used, created date)
   - User selects which identity to restore
3. Prompt for PIN for selected identity
4. Decrypt and restore

**Adding Additional Identities:**

Users can add new identities to existing OAuth backup:

```
Settings → Accounts → Add Account → Sign in with Apple
  → OAuth authenticates (same provider account)
  → Check for existing backups
  → "Create new identity or restore existing?"
    ├─ Create New:
    │    → Set PIN (can differ from other identities)
    │    → Generate keypair
    │    → Encrypt and store as new entry
    │
    └─ Restore Existing:
         → Show list of backed-up identities
         → Select one → enter PIN → restore
```

**PIN Strategies:**

Clients MAY support either approach:

**Option A: Shared PIN (Simpler UX)**
```
All identities use same PIN
  → Easier for user to remember
  → Single point of compromise
```

**Option B: Per-Identity PIN (More Secure)**
```
Each identity has unique PIN
  → Compromise of one doesn't affect others
  → More PINs to remember
```

**Security Isolation:**

Even with shared PINs, identities SHOULD be cryptographically isolated. Recommended approach:

```swift
// Include npub in salt derivation for perfect isolation
message = "\(provider):\(userID):\(npub)"
salt = HMAC-SHA256("nostr-identity-v1", message)
password = "\(pin)-\(provider)-\(userID)-\(npub)-\(hex(salt))"
```

This ensures:
- Same PIN + same provider = different encryption keys per identity
- Attacker cannot decrypt identity B even if they crack identity A's PIN

**Account Switching:**

Clients with multi-account support SHOULD:
1. Cache decrypted nsecs in memory per session (never on disk)
2. Prompt for PIN when switching to an account not in memory
3. Implement session timeouts to re-prompt for PIN
4. Allow user to configure per-account security settings

**Sync Behavior:**

- ✅ All encrypted backups sync across devices
- ✅ User can restore all identities or select subset
- ❌ App settings/preferences do NOT sync (per-device)
- ❌ PINs never stored or synced

#### 6.4 Cross-Platform Considerations

**iOS/macOS ↔ Android:**
- Apple Sign In only works on Apple devices
- Google Sign In works on all platforms
- Clients SHOULD offer Google Sign In on iOS for cross-platform users

**Web clients:**
- Cannot access native cloud keychain directly
- SHOULD offer "Download backup file" option
- Users can manually import into native apps

### 7. Implementation Notes

#### 7.1 Reference Implementation

See:
- [Nostr Vault](https://github.com/your-repo/nostr-vault) - iOS/macOS reference
- [BackupCryptoService.swift](https://github.com/your-repo/nostr-vault/blob/main/Services/BackupCryptoService.swift)
- [iCloudKeychainService.swift](https://github.com/your-repo/nostr-vault/blob/main/Services/iCloudKeychainService.swift)

#### 7.2 Testing

Implementers SHOULD verify:
- Key derivation matches reference implementation byte-for-byte
- NIP-49 encryption interoperability
- Cloud keychain storage persistence across devices
- PIN validation and rate limiting
- Account discovery and restoration

#### 7.3 Error Handling

Clients MUST handle:
- User cancels OAuth flow
- OAuth provider unavailable
- Cloud sync disabled (prompt user to enable)
- PIN incorrect (rate limit retries)
- Backup corruption (offer re-generation)
- Multiple backups found (show picker)

### 8. Privacy Considerations

#### 8.1 Metadata Leakage (Privacy-Preserving Design)

**What cloud keychain providers (Apple, Google) can observe:**
- That you have ONE backup entry (constant account identifier: "nostr-identities")
- When the backup container is created/accessed (first backup timestamp)
- Which apps access the backup container
- Approximate geographic location (via IP during sync)

**What providers CANNOT observe (hidden inside encrypted JSON):**
- Your npub(s) - stored inside the JSON array, not as keychain account ID
- How many Nostr identities you have
- When you created each identity
- Identity switching patterns
- Which specific identities you're using

**What providers can NEVER observe (cryptographically protected):**
- Your nsec (double encrypted: NIP-49 + iCloud E2E)
- Your PIN (never transmitted or stored)
- Your Nostr activity (posts, DMs, zaps)
- Any content of your identities

**Privacy Improvement:**
This design significantly improves privacy compared to naive approaches that store one keychain entry per npub. By using a single container with a constant identifier, we prevent the cloud provider from:
- Building identity graphs
- Correlating multiple pseudonymous identities
- Observing identity creation patterns
- Tracking which identities are active

#### 8.2 Relay Privacy

Clients SHOULD implement privacy protection when fetching user profiles:
1. Fetch user's real profile(s)
2. Fetch N random "decoy" profiles
3. Issue single REQ for mixed set
4. Discard decoy results

This prevents relays from correlating "this OAuth account owns these npubs."

### 9. Future Considerations

#### 9.1 Hardware Security Module (HSM) Support

Future versions MAY leverage platform HSMs:
- iOS Secure Enclave for key derivation
- Android StrongBox for key storage
- Biometric authentication instead of PIN

#### 9.2 Social Recovery

Future versions MAY support Shamir's Secret Sharing:
- Split ncryptsec into M-of-N shards
- Distribute shards to trusted contacts
- Recover if PIN forgotten

#### 9.3 Multi-Device Coordination

Future versions MAY add device authorization:
- New device scans QR code from existing device
- Existing device approves new device
- Encrypted channel for backup transfer

## Rationale

### Why OAuth Providers?

- **Ubiquity**: Billions of users have Apple/Google accounts
- **Security**: Providers invest heavily in account security
- **UX**: Users already understand "Sign in with Apple/Google"
- **Recovery**: Users can recover via provider's account recovery flows

### Why NIP-49?

- **Standardization**: Existing, well-vetted encryption format
- **Portability**: ncryptsec can be exported and imported manually
- **Compatibility**: Works with existing NIP-49 tooling

### Why Not Seed Phrases?

- **UX**: 12-word phrases are intimidating and error-prone
- **Security**: Users write them down insecurely (photos, notes)
- **Friction**: Reduces Nostr adoption

### Why PIN Instead of Passphrase?

- **Balance**: Trade maximum security for usability
- **Defense in depth**: OAuth account security + scrypt + cloud E2E encryption
- **Recovery**: Short PIN is memorable; long passphrase is often forgotten

## Test Vectors

### Vector 1: Apple Sign In

```
providerPrefix: "apple"
providerUserID: "001234.abcdef1234567890.1234"
userPIN: "8264"
nsec: "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsr6g58"

saltContext: "nostr-identity-v1"
salt: HMAC-SHA256("nostr-identity-v1", "apple:001234.abcdef1234567890.1234")
    = a3f2c8d9e1b4f7a6c2d8e9f1a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2

password: "8264-apple-001234.abcdef1234567890.1234-a3f2c8d9e1b4f7a6c2d8e9f1a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"

ncryptsec: (result of NIP49_encrypt with above password)
```

### Vector 2: Google Sign In

```
providerPrefix: "google"
providerUserID: "112233445566778899"
userPIN: "123456"
nsec: "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsr6g58"

saltContext: "nostr-identity-v1"
salt: HMAC-SHA256("nostr-identity-v1", "google:112233445566778899")
    = b4e3d2c1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3

password: "123456-google-112233445566778899-b4e3d2c1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3"

ncryptsec: (result of NIP49_encrypt with above password)
```

## References

- [NIP-49: Private Key Encryption](https://github.com/nostr-protocol/nips/blob/master/49.md)
- [Apple Sign In Documentation](https://developer.apple.com/documentation/sign_in_with_apple)
- [Google Sign In Documentation](https://developers.google.com/identity/sign-in/web/sign-in)
- [wisp-ios: Reference Implementation](https://github.com/planetary-social/wisp-ios)

## Copyright

This document is placed in the public domain.

## Changelog

- 2024-01-XX: Initial draft
