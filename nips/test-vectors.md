# Test Vectors for NIP: OAuth Identity Backup

This document contains test vectors for implementers to verify correctness.

## Vector 1: Apple Sign In (4-digit PIN)

### Inputs
```
Provider: "apple"
Provider User ID: "001234.abcdef1234567890.1234"
User PIN: "8264"
nsec: "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsr6g58"
```

### Intermediate Values

**Salt Context:**
```
"nostr-identity-v1"
```

**HMAC-SHA256 Input:**
```
key: "nostr-identity-v1" (UTF-8 bytes)
message: "apple:001234.abcdef1234567890.1234" (UTF-8 bytes)
```

**Salt (hex):**
```
TODO: Calculate actual HMAC-SHA256 output
```

**Derived Password:**
```
"8264-apple-001234.abcdef1234567890.1234-<salt_hex>"
```

### Expected Output

**ncryptsec:**
```
TODO: Calculate actual NIP-49 encryption output
```

---

## Vector 2: Google Sign In (6-digit PIN)

### Inputs
```
Provider: "google"
Provider User ID: "112233445566778899"
User PIN: "123456"
nsec: "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsr6g58"
```

### Intermediate Values

**Salt Context:**
```
"nostr-identity-v1"
```

**HMAC-SHA256 Input:**
```
key: "nostr-identity-v1" (UTF-8 bytes)
message: "google:112233445566778899" (UTF-8 bytes)
```

**Salt (hex):**
```
TODO: Calculate actual HMAC-SHA256 output
```

**Derived Password:**
```
"123456-google-112233445566778899-<salt_hex>"
```

### Expected Output

**ncryptsec:**
```
TODO: Calculate actual NIP-49 encryption output
```

---

## Vector 3: Edge Case - 8-digit PIN with Special Characters in Provider ID

### Inputs
```
Provider: "apple"
Provider User ID: "001999.xyz-abc_123.9999"
User PIN: "99887766"
nsec: "nsec1l3zqvqlup7w8hwgky8kj2wkmf6h37pz8sepkph8uwtgh7pjcxytq0gcph9"
```

### Intermediate Values

**Salt Context:**
```
"nostr-identity-v1"
```

**HMAC-SHA256 Input:**
```
key: "nostr-identity-v1" (UTF-8 bytes)
message: "apple:001999.xyz-abc_123.9999" (UTF-8 bytes)
```

**Salt (hex):**
```
TODO: Calculate actual HMAC-SHA256 output
```

**Derived Password:**
```
"99887766-apple-001999.xyz-abc_123.9999-<salt_hex>"
```

### Expected Output

**ncryptsec:**
```
TODO: Calculate actual NIP-49 encryption output
```

---

## How to Generate Test Vectors

### Step 1: Calculate HMAC-SHA256

```swift
import CryptoKit

func calculateSalt(provider: String, userID: String) -> String {
    let saltContext = "nostr-identity-v1"
    let message = "\(provider):\(userID)"
    let key = SymmetricKey(data: Data(saltContext.utf8))
    let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
    return Data(mac).map { String(format: "%02x", $0) }.joined()
}

// Example:
let salt = calculateSalt(provider: "apple", userID: "001234.abcdef1234567890.1234")
print(salt)
```

### Step 2: Derive Password

```swift
func derivePassword(pin: String, provider: String, userID: String, salt: String) -> String {
    return "\(pin)-\(provider)-\(userID)-\(salt)"
}
```

### Step 3: Encrypt with NIP-49

```swift
// Use NIP-49 reference implementation
let ncryptsec = try NIP49Service.encrypt(nsec: nsec, password: password)
print(ncryptsec)
```

---

## Verification

Implementers should verify:

1. **Salt calculation matches** across all implementations
2. **Password format is identical** (exact string concatenation)
3. **NIP-49 encryption produces same ncryptsec** for same inputs
4. **Decryption recovers original nsec** correctly

### Cross-Implementation Test

```
1. Generate test vector in Swift implementation
2. Import ncryptsec into Kotlin implementation
3. Decrypt with same PIN + provider ID
4. Verify nsec matches original
```

---

## TODO

- [ ] Generate actual HMAC-SHA256 values for all vectors
- [ ] Generate actual ncryptsec values using NIP-49 reference
- [ ] Add more edge cases (empty strings, Unicode, max lengths)
- [ ] Create automated test suite
- [ ] Verify against wisp-ios implementation
