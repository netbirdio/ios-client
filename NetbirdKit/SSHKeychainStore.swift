//
//  SSHKeychainStore.swift
//  NetbirdKit
//

import Security
import Foundation

enum SSHKeychainStore {
    private static let service = "io.netbird.ssh.passwords"

    @discardableResult
    static func save(password: String, for sessionID: String) -> Bool {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionID,
        ]
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            return SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess
        } else {
            var add = query
            add[kSecValueData as String] = data
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
    }

    static func load(for sessionID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for sessionID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionID,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
