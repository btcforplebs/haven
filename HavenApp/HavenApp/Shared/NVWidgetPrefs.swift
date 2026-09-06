import Foundation
import Security

// MARK: - Widget preferences
//
// State a widget sets for itself, as opposed to state the app hands it.
//
// Mosaic's filter chips are buttons inside the widget, so the choice is made in
// the widget extension's process and has to survive until the next timeline is
// built — in a third process, minutes later. A `WidgetConfigurationIntent`
// parameter would be the usual home for this, but that is edited through
// long-press → Edit Widget, and the ask here was a filter you can hit from the
// widget face.
//
// So it lives beside the snapshot, in the same shared keychain group, as its
// own small item: this is written by the widget and read by the widget, and it
// must not be clobbered when the app republishes a snapshot.
struct NVWidgetPrefs: Codable, Equatable {
    var mosaicFilter: NVMediaFilter

    static let `default` = NVWidgetPrefs(mosaicFilter: .all)
}

enum NVWidgetPrefsStore {
    private static let service = "to.nostrvault.widget"
    private static let account = "prefs.v1"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: NVSharedStore.accessGroup,
        ]
    }

    static func load() -> NVWidgetPrefs {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let prefs = try? JSONDecoder().decode(NVWidgetPrefs.self, from: data)
        else { return .default }
        return prefs
    }

    @discardableResult
    static func save(_ prefs: NVWidgetPrefs) -> Bool {
        guard let data = try? JSONEncoder().encode(prefs) else { return false }
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
}
