# How Signing Works with Apple Sign In in Nostr Vault

## Overview

When you use "Sign in with Apple" in Nostr Vault, your Nostr private key (nsec) is **never stored in plaintext anywhere**. This document explains the complete technical flow of how signing works, from setup to event signing.

## Setup Flow

### 1. Initial Sign In with Apple

```
User taps "Sign in with Apple"
   ↓
iOS/macOS shows native Apple authentication sheet
   ↓
User authenticates with Face ID/Touch ID/Password
   ↓
Apple returns stable, opaque userID (team-scoped identifier)
   ↓
App stores userID temporarily (not persisted)
```

**Key Point**: The Apple `userID` is:
- Stable (same forever for this app + Apple ID combo)
- Opaque (not your email or personal info)
- Team-scoped (unique to your Apple Developer Team ID)
- **Not a secret** (just used for salt derivation)

### 2. Check for Existing Backups

```
App queries iCloud Keychain for existing backups
   ↓
If backups found → Go to PIN entry for restore
If no backups → Go to PIN setup for new account
```

### 3a. New Account Flow (No Existing Backups)

```
User sets 4-8 digit PIN
   ↓
User confirms PIN
   ↓
App generates new Nostr keypair:
  - privkey: 32 random bytes (via Schnorr.randomPrivkey())
  - pubkey: secp256k1 x-only public key
   ↓
Derive encryption password:
  password = PIN + "-" + appleUserID + "-" + HMAC-SHA256("nostr-vault-apple-backup-v1", appleUserID)
   ↓
Encrypt nsec with NIP-49 (scrypt + XChaCha20-Poly1305):
  ncryptsec = NIP49.encrypt(nsec, password)
   ↓
Store ncryptsec in iCloud Keychain:
  - Service: "com.nostrvault.apple-backup"
  - Account: npub
  - Data: ncryptsec
  - kSecAttrSynchronizable: true (enables iCloud sync)
   ↓
Done! User can now sign events
```

### 3b. Restore Flow (Existing Backups Found)

```
User enters PIN
   ↓
Derive decryption password:
  password = PIN + "-" + appleUserID + "-" + HMAC-SHA256("nostr-vault-apple-backup-v1", appleUserID)
   ↓
Try to decrypt each backup:
  nsec = NIP49.decrypt(ncryptsec, password)
   ↓
If decryption succeeds → Derive npub, show account selector
If all fail → Show "Incorrect PIN" error
   ↓
User selects account to restore
   ↓
Done! nsec is restored
```

## Event Signing Flow

When the user needs to sign a Nostr event (post a note, send a DM, send a zap, etc.):

### The 5-Step Signing Process

```
┌─────────────────────────────────────────────────────────┐
│ Step 1: Retrieve Encrypted Backup from iCloud Keychain │
└─────────────────────────────────────────────────────────┘
                          ↓
Query iCloud Keychain:
  - Service: "com.nostrvault.apple-backup"
  - Account: npub
  - Returns: ncryptsec (encrypted nsec)

┌─────────────────────────────────────────────────────────┐
│ Step 2: Derive Decryption Key from Apple ID + PIN      │
└─────────────────────────────────────────────────────────┘
                          ↓
password = PIN + "-" + appleUserID + "-" + HMAC-SHA256(salt, appleUserID)

┌─────────────────────────────────────────────────────────┐
│ Step 3: Decrypt nsec Temporarily in Memory             │
└─────────────────────────────────────────────────────────┘
                          ↓
nsec = NIP49.decrypt(ncryptsec, password)
// nsec now exists in memory as plaintext Data

┌─────────────────────────────────────────────────────────┐
│ Step 4: Sign the Nostr Event with Schnorr Signature    │
└─────────────────────────────────────────────────────────┘
                          ↓
1. Serialize event to canonical JSON
2. Hash with SHA-256 to get event ID
3. Sign hash with Schnorr.sign(eventID, nsec)
4. Add signature to event JSON

┌─────────────────────────────────────────────────────────┐
│ Step 5: Immediately Discard the Decrypted Key          │
└─────────────────────────────────────────────────────────┘
                          ↓
nsec variable goes out of scope
Memory is zeroed (Swift's ARC deallocates)
Plaintext nsec no longer exists anywhere
```

**Time in memory**: The decrypted nsec exists in plaintext for **milliseconds** — only during the signing operation. As soon as the signature is computed, the nsec is discarded.

## Security Properties

### What's Encrypted?

1. **NIP-49 Layer** (App-side encryption):
   - Algorithm: scrypt (N=2^20, r=8, p=1) + XChaCha20-Poly1305
   - Password: Derived from PIN + Apple userID
   - Format: `ncryptsec1...` bech32 string

2. **iCloud Keychain Layer** (Apple's encryption):
   - End-to-end encrypted by Apple
   - Encrypted with keys derived from device passcode + iCloud password
   - Syncs across user's devices via iCloud Keychain circle of trust

### What Apple Can See?

- ❌ Your nsec (encrypted twice)
- ❌ Your PIN (never leaves your device)
- ✅ Your Apple userID (they generated it)
- ✅ Your encrypted backup blob (but can't decrypt it)
- ✅ Metadata (npub, timestamps, device sync info)

### Attack Scenarios

#### Scenario 1: Attacker Compromises iCloud Account

```
Attacker gains access to victim's iCloud account
   ↓
Downloads ncryptsec from iCloud Keychain
   ↓
Needs to crack NIP-49 encryption
   ↓
Tries PIN brute force:
  - 4 digits: 10,000 combinations
  - 8 digits: 100,000,000 combinations
   ↓
Each attempt requires:
  - scrypt KDF (memory-hard, ~16MB RAM per attempt)
  - Takes ~1 second per attempt on modern CPU
   ↓
Time to crack:
  - 4 digit PIN: ~3 hours (10,000 seconds)
  - 6 digit PIN: ~12 days (1,000,000 seconds)
  - 8 digit PIN: ~3 years (100M seconds)
```

**Defense**: Use an 8-digit PIN for maximum security.

#### Scenario 2: Attacker Has Both iCloud + Sees PIN Entry

```
Attacker:
  1. Compromises iCloud account
  2. Shoulder-surfs or records PIN entry
   ↓
Can immediately decrypt nsec and steal keys
```

**Defense**: This is the fundamental trade-off of this system. Protect your Apple account with strong 2FA and never enter your PIN where you can be observed.

#### Scenario 3: Malicious App on Same iCloud Account

```
Malicious app tries to access iCloud Keychain
   ↓
Blocked by:
  - Service identifier: "com.nostrvault.apple-backup"
  - App sandboxing (each app has separate keychain)
  - Code signing (only Nostr Vault bundle ID can access)
```

**Defense**: iOS/macOS sandboxing prevents other apps from accessing your keychain items.

## Normal Flow vs Apple Sign In

### Normal Nostr Vault Flow

```
1. User enters/generates nsec
2. User sets password for NIP-49 encryption
3. ncryptsec stored in local Keychain
4. Password stored in local Keychain
5. Signing:
   - Retrieve ncryptsec from Keychain
   - Retrieve password from Keychain
   - Decrypt with NIP49
   - Sign event
   - Discard plaintext nsec
```

**Storage**: Local device keychain only (no iCloud sync)

### Apple Sign In Flow

```
1. User signs in with Apple
2. App generates/restores nsec
3. User sets PIN
4. Derive password from (Apple ID + PIN)
5. Encrypt with NIP-49
6. Store ncryptsec in iCloud Keychain
7. Signing:
   - Retrieve ncryptsec from iCloud Keychain
   - Derive password from (Apple ID + PIN)
   - Decrypt with NIP49
   - Sign event
   - Discard plaintext nsec
```

**Storage**: iCloud Keychain (syncs across all user's Apple devices)

## Key Differences

| Aspect | Normal Flow | Apple Sign In |
|--------|-------------|---------------|
| **Storage** | Local Keychain | iCloud Keychain |
| **Sync** | No | Yes (across devices) |
| **Password** | User-chosen | Derived from PIN + Apple ID |
| **Recovery** | Manual backup of ncryptsec | Automatic via iCloud |
| **Portability** | Export ncryptsec manually | Auto-sync to new devices |
| **Security** | Depends on password strength | Depends on iCloud + PIN |
| **Apple Dependency** | None | Requires Apple account |

## Trade-Offs Summary

### Advantages ✅

- **Seamless multi-device sync**: Sign in on any Apple device with same Apple ID + PIN
- **No manual backups**: iCloud handles sync automatically
- **No seed phrases**: No need to write down or memorize long strings
- **Fast recovery**: Restore on new device in seconds
- **Two-layer encryption**: NIP-49 + iCloud's E2E encryption

### Disadvantages ❌

- **Requires iCloud**: Must have iCloud sign-in enabled
- **Apple dependency**: Losing Apple account = losing keys
- **PIN security**: 4-8 digits is weaker than a strong passphrase
- **Apple visibility**: Apple can see encrypted backups (but not decrypt)
- **Single point of failure**: Apple account + PIN is all you need

## Quote

> "There are no solutions, only trade-offs."
> — Gigi

This system trades **absolute maximum security** (manual key management, long passphrases, airgapped signing) for **convenience** (seamless sync, easy recovery, no seed phrases). For most users, the convenience is worth the trade-off — especially given that:

1. iCloud account security is strong (2FA, device trust)
2. Two-layer encryption makes offline attacks expensive
3. Most Nostr users don't have high-value targets on their keys
4. Alternative is often worse: plaintext nsec screenshots in iCloud Photos

The goal is to make Nostr accessible while keeping security reasonable, not to achieve theoretical maximum security at the expense of usability.
