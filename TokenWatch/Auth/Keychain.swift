//
//  Keychain.swift
//  TokenWatch
//
//  토큰 저장용 iOS Keychain 최소 래퍼 (generic password).
//

import Foundation
import Security

nonisolated enum Keychain {
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

    /// 읽기 결과. "항목 없음"과 "지금은 읽을 수 없음"을 구분한다.
    enum Lookup {
        case found(Data)
        /// 항목이 없다(또는 아래 `unavailable`이 아닌 이유로 읽지 못했다 — 기존과 같이 없음으로 본다).
        case missing
        /// 기기 데이터 보호 때문에 지금은 읽을 수 없다(`errSecInteractionNotAllowed` — 재시동 뒤 첫 잠금 해제 전 등).
        /// 항목은 그대로 있으니 없음으로 다루면 안 된다.
        case unavailable
    }

    static func lookup(account: String) -> Lookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return lookup(status: status, result: result)
    }

    /// `SecItemCopyMatching` 결과 → `Lookup`(순수 함수 — 테스트 대상).
    static func lookup(status: OSStatus, result: AnyObject?) -> Lookup {
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .missing }
            return .found(data)
        case errSecInteractionNotAllowed:
            return .unavailable
        default:
            return .missing
        }
    }

    static func data(account: String) -> Data? {
        if case .found(let data) = lookup(account: account) { return data }
        return nil
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
