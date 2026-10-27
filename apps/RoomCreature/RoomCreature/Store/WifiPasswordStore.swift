import Foundation
import Security

/// A Wi-Fi password the user typed during a successful creature setup, remembered in the Keychain.
struct SavedWifiPassword: Identifiable, Hashable, Sendable {
    let ssid: String
    /// When the item was last written; nil only if the Keychain did not report a date.
    let savedAt: Date?

    var id: String { ssid }
}

/// Wi-Fi passwords in the Keychain: one generic-password item per network, service
/// `com.harshsah.roomcreature.wifi`, account = SSID. The Security calls are synchronous and
/// thread-safe, so the store is a namespace of nonisolated functions.
enum WifiPasswordStore {
    static let service = "com.harshsah.roomcreature.wifi"

    /// The saved password for a network, with the date it was saved, or nil when there is none.
    static func password(for ssid: String) -> (password: String, savedAt: Date?)? {
        var query = baseQuery(ssid: ssid)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8)
        else { return nil }
        return (password, item[kSecAttrModificationDate as String] as? Date)
    }

    /// Every saved network, most recently saved first.
    static func all() -> [SavedWifiPassword] {
        var query = baseQuery(ssid: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items
            .compactMap { item -> SavedWifiPassword? in
                guard let ssid = item[kSecAttrAccount as String] as? String, !ssid.isEmpty else { return nil }
                return SavedWifiPassword(ssid: ssid, savedAt: item[kSecAttrModificationDate as String] as? Date)
            }
            .sorted { ($0.savedAt ?? .distantPast, $0.ssid) > ($1.savedAt ?? .distantPast, $1.ssid) }
    }

    /// Saves (or replaces) the password for a network. Returns false if the Keychain refused.
    @discardableResult
    static func save(_ password: String, for ssid: String) -> Bool {
        guard !ssid.isEmpty, !password.isEmpty else { return false }
        SecItemDelete(baseQuery(ssid: ssid) as CFDictionary)
        var attributes = baseQuery(ssid: ssid)
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrLabel as String] = "RoomCreature Wi-Fi: \(ssid)"
        #if os(iOS)
        // The data-protection keychain honours accessibility; the file-based Mac keychain ignores it.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        #endif
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Removes the saved password for a network (no-op if there is none).
    static func forget(_ ssid: String) {
        SecItemDelete(baseQuery(ssid: ssid) as CFDictionary)
    }

    private static func baseQuery(ssid: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let ssid { query[kSecAttrAccount as String] = ssid }
        return query
    }
}
