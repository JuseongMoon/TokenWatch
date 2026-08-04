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

    /// 저장 성공 여부를 돌려준다 — 실패를 조용히 넘기면 "에이전트는 있는데 토큰만 없는"
    /// 영구 고장 상태가 되므로, 로그인 경로(addAgent)는 이 값을 확인해야 한다.
    @discardableResult
    static func set(_ data: Data, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        // AfterFirstUnlock: 백그라운드 갱신(BGAppRefreshTask)이 잠금 중에도 읽어야 한다.
        // ThisDeviceOnly: 토큰이 암호화 백업에 실려 다른 기기로 이관되지 않게 한다.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
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

    @discardableResult
    static func setJSON<T: Encodable>(_ value: T, account: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        return set(data, account: account)
    }

    static func json<T: Decodable>(_ type: T.Type, account: String) -> T? {
        guard let data = data(account: account) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
