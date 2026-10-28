import Foundation
import Security

/// What this device keeps about one hub, in the Keychain: the certificate fingerprint pinned at
/// pairing, and the device token the hub issued. One generic-password item per hub, service
/// `com.harshsah.roomcreature.hub`, account = the hub's identity (Bonjour name or `host:port`).
/// The token is a secret: never log it.
struct HubCredentials: Codable, Equatable, Sendable {
    /// SHA-256 of the hub certificate's DER, lowercase hex.
    var fingerprint: String?
    var token: String?
    var deviceID: String?
    /// The name this device paired under.
    var deviceName: String?

    var isPaired: Bool { token?.isEmpty == false }

    static let service = "com.harshsah.roomcreature.hub"

    /// The first 16 hex characters of a fingerprint in groups of four, for people to compare.
    static func shortFingerprint(_ fingerprint: String) -> String {
        let head = Array(fingerprint.lowercased().prefix(16))
        return stride(from: 0, to: head.count, by: 4)
            .map { String(head[$0..<min($0 + 4, head.count)]) }
            .joined(separator: " ")
    }

    static func load(for identity: String) -> HubCredentials? {
        var query = baseQuery(identity)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(HubCredentials.self, from: data)
    }

    /// Saves (or replaces) the credentials for a hub. Returns false if the Keychain refused.
    @discardableResult
    static func save(_ credentials: HubCredentials, for identity: String) -> Bool {
        guard !identity.isEmpty, let data = try? JSONEncoder().encode(credentials) else { return false }
        SecItemDelete(baseQuery(identity) as CFDictionary)
        var attributes = baseQuery(identity)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "Fennec hub: \(identity)"
        #if os(iOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Removes everything kept for a hub: token, device id and pinned fingerprint.
    static func forget(_ identity: String) {
        SecItemDelete(baseQuery(identity) as CFDictionary)
    }

    private static func baseQuery(_ identity: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identity,
        ]
    }
}
