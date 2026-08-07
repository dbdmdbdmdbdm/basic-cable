import Foundation
import Security

/// Settings shared between the tvOS app and its Top Shelf extension via a
/// shared keychain access group — chosen over an App Group container
/// because keychain groups under the team prefix need NO developer-portal
/// registration (provisioning profiles cover `TEAMID.*` automatically),
/// so any open-source builder's team works out of the box.
enum SharedConfig {
    /// Suffix of the shared keychain access group; the full group is
    /// `<AppIdentifierPrefix><suffix>`, resolved from Info.plist (the
    /// `AppIdentifierPrefix` key is stamped at build time).
    private static let groupSuffix = "com.dbdm.tunarrtv.shared"

    private static var accessGroup: String? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
              !prefix.isEmpty else { return nil }
        return prefix + groupSuffix
    }

    private static func query(for key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.dbdm.tunarrtv.topshelf-config",
            kSecAttrAccount as String: key,
        ]
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    static func set(_ value: String, forKey key: String) {
        var attributes = query(for: key)
        SecItemDelete(attributes as CFDictionary)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        var query = query(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
