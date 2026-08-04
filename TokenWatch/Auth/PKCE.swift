//
//  PKCE.swift
//  TokenWatch
//
//  OAuth 2.0 PKCE (Proof Key for Code Exchange) 파라미터 생성.
//

import Foundation
import CryptoKit

struct PKCE: Sendable {
    let verifier: String
    let challenge: String
    let state: String

    init() {
        verifier = Self.randomURLSafe(byteCount: 32)
        state = Self.randomURLSafe(byteCount: 32)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        challenge = Data(digest).base64URLEncodedString()
    }

    private static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            // 실패를 무시하면 verifier/state가 전부 0바이트로 통과한다 —
            // 시스템 CSPRNG(arc4random 계열)로 폴백해 엔트로피를 보장한다.
            var rng = SystemRandomNumberGenerator()
            for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max, using: &rng) }
        }
        return Data(bytes).base64URLEncodedString()
    }
}

extension Data {
    /// base64url (padding 없음).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
