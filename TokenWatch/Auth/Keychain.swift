//
//  Keychain.swift
//  TokenWatch
//
//  토큰 저장용 iOS Keychain 최소 래퍼 (generic password).
//

import Foundation
import Security

enum Keychain {
    /// 우리 앱 전용 서비스 네임스페이스.
    private static let service = "com.ScienceFiction.TokenWatch.oauth"

    static func set(_ data: Data, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func data(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Codable 편의

    static func setJSON<T: Encodable>(_ value: T, account: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        set(data, account: account)
    }

    static func json<T: Decodable>(_ type: T.Type, account: String) -> T? {
        guard let data = data(account: account) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
