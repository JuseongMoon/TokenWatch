//
//  WindsurfAuth.swift
//  TokenWatch
//
//  Windsurf 로그인 — WKWebView로 로그인시킨 뒤 localStorage의 인증 토큰을 캡처한다.
//  쿠키가 아니라 localStorage에 토큰이 저장되므로 LoginWebView의 localStorage 폴링을 쓴다.
//
//  ⚠️ localStorage 키 이름과 전송 헤더는 리버스 엔지니어링 기반(검증 대상)이다.
//     찾은 키를 표준 헤더명(x-auth-token / x-devin-*)으로 매핑해 API 호출 시 헤더로 보낸다.
//

import Foundation

enum WindsurfAuth {
    static let loginURL = URL(string: "https://windsurf.com/account")!

    /// localStorage 키(부분일치, 소문자) → 전송 헤더명. 구체적인 것 먼저 확인한다.
    private static let mapping: [(header: String, needle: String)] = [
        ("x-devin-auth1-token",    "auth1-token"),
        ("x-devin-session-token",  "session-token"),
        ("x-devin-account-id",     "account-id"),
        ("x-devin-primary-org-id", "primary-org-id"),
        ("x-devin-primary-org-id", "org-id"),
        ("x-auth-token",           "auth-token"),   // auth1은 위에서 이미 매핑됨
    ]

    /// localStorage 전체에서 인증 헤더들을 추려 자격증명(JSON 패킹)으로 만든다.
    /// 핵심 토큰(x-auth-token 또는 session-token)이 있어야 로그인 완료로 간주.
    static func localStorageProbe(_ store: [String: String]) -> OAuthTokens? {
        var headers: [String: String] = [:]
        for (key, value) in store where !value.isEmpty {
            let lower = key.lowercased()
            for (header, needle) in mapping where headers[header] == nil && lower.contains(needle) {
                headers[header] = value
                break
            }
        }
        guard headers["x-auth-token"] != nil || headers["x-devin-session-token"] != nil else { return nil }
        guard let json = try? JSONSerialization.data(withJSONObject: headers),
              let packed = String(data: json, encoding: .utf8) else { return nil }
        return OAuthTokens.session(packed)
    }
}
