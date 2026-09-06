import Foundation
import Security

// MARK: - Shared Store
//
// Cross-process handoff of the widget snapshot, over a shared keychain access
// group rather than an App Group container.
//
// Why not an App Group: `com.apple.security.application-groups` is a managed
// capability. The group has to be registered on the developer portal and appear
// in the provisioning profile, and there is no Apple ID signed into Xcode on
// this machine to register one. Neither profile available here carries an app
// group -- but both carry `keychain-access-groups: 525WQ48Y72.*`, and a
// wildcard grant means any group under that team prefix is usable without
// registering anything.
//
// The cost is that a keychain item is a poor filesystem. Items are small and
// each read is a syscall, so the snapshot stays lean and is written whole
// rather than incrementally. If an Apple ID is ever added to Xcode, swapping
// the two `load`/`save` bodies for a file in an App Group container is the
// entire migration.

enum NVSharedStore {
    /// Any group under the team prefix works; the wildcard profile grants them all.
    static let accessGroup = "525WQ48Y72.nostrvault.shared"
    private static let service = "to.nostrvault.widget"
    private static let account = "snapshot.v1"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    /// Reads the last snapshot the app wrote. Returns nil when the app has
    /// never run, or when the keychain is still locked after a cold boot --
    /// both are ordinary states for a widget, not errors.
    static func load() -> NVWidgetSnapshot? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(NVWidgetSnapshot.self, from: data)
    }

    /// Writes the snapshot, replacing any previous one.
    ///
    /// `kSecAttrAccessibleAfterFirstUnlock` is deliberate: widgets refresh in
    /// the background, including while the device is locked. The default
    /// (`WhenUnlocked`) would make every timeline reload after a lock fail to
    /// read anything, and the widgets would go blank on the Lock Screen -- the
    /// one place they most need to work.
    @discardableResult
    static func save(_ snapshot: NVWidgetSnapshot) -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var insert = baseQuery
        insert.merge(attributes) { _, new in new }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
