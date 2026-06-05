# Nostr Implementation Possibilities (NIPs)

This folder contains NIP proposals developed as part of the Nostr Vault project.

## Proposals

### NIP-OAUTH-IDENTITY-BACKUP.md

**Status:** Draft
**Title:** Universal Nostr Identity Backup via OAuth Provider Sign-In
**Type:** Informational

**Summary:**
Defines a standard protocol for backing up Nostr identities to cloud keychain services (iCloud, Google Smart Lock) using OAuth provider authentication. Enables cross-app identity portability where users can restore the same nsec in any compliant Nostr client.

**Key Features:**
- Universal namespace: `com.nostr.identity.backup`
- Standard key derivation from PIN + OAuth provider ID
- NIP-49 encryption (scrypt + XChaCha20-Poly1305)
- Multi-provider support (Apple, Google, future providers)
- Cross-app compatibility (Nostr Vault ↔ Damus ↔ Primal, etc.)

**Implementation:**
- Reference implementation in [BackupCryptoService.swift](../HavenApp/HavenApp/Services/BackupCryptoService.swift)
- Reference implementation in [iCloudKeychainService.swift](../HavenApp/HavenApp/Services/iCloudKeychainService.swift)
- Reference implementation in [AppleSignInManager.swift](../HavenApp/HavenApp/Services/AppleSignInManager.swift)

**Next Steps:**
1. Generate actual test vectors (HMAC-SHA256 values)
2. Get feedback from Nostr client developers
3. Submit PR to [nostr-protocol/nips](https://github.com/nostr-protocol/nips)
4. Coordinate implementation across apps

---

## Contributing

If you'd like to propose a new NIP or provide feedback on existing ones:

1. **For new NIPs:** Create a new `.md` file in this folder following the [NIP template](https://github.com/nostr-protocol/nips/blob/master/00.md)
2. **For feedback:** Open an issue in this repository or contact the authors
3. **For implementation:** Reference implementations should go in `/HavenApp/HavenApp/Services/`

## Resources

- [Official NIPs Repository](https://github.com/nostr-protocol/nips)
- [NIP-01: Basic Protocol](https://github.com/nostr-protocol/nips/blob/master/01.md)
- [How to Write a NIP](https://github.com/nostr-protocol/nips#how-to-submit-a-nip)

## License

All NIPs in this folder are placed in the public domain unless otherwise specified.
