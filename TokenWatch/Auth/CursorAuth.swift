//
//  CursorAuth.swift
//  TokenWatch
//
//  Cursor 로그인 — WKWebView로 cursor.com에 로그인시킨 뒤 세션 쿠키를 캡처한다.
//  OAuth가 아니라 브라우저 세션 쿠키(WorkosCursorSessionToken) 기반이다.
//
//  ⚠️ 로그인 URL·쿠키명·사용량 엔드포인트는 공개 문서가 아닌 내부(리버스 엔지니어링)
//     값이라 벤더가 예고 없이 바꿀 수 있다. 실제 로그인으로 검증하며 상수만 조정한다.
//     (쿠키 값 형식: "<user_id>::<jwt>", URL 인코딩 시 "%3A%3A".)
//

import Foundation

enum CursorAuth {
    /// 로그인 웹뷰 시작 URL. 미인증 시 로그인 페이지로 유도되고, 성공 후 cursor.com에
    /// WorkosCursorSessionToken 쿠키가 설정된다.
    static let loginURL = URL(string: "https://cursor.com/dashboard")!
    static let cookieName = "WorkosCursorSessionToken"

    /// 쿠키 목록에서 세션 토큰을 찾으면 자격증명으로 만든다(없으면 nil → 계속 관찰).
    /// accessToken엔 쿠키 값 전체, accountId엔 user_id를 담는다(usage?user= 호출용).
    static func sessionProbe(_ cookies: [HTTPCookie]) -> OAuthTokens? {
        guard let cookie = cookies.first(where: { $0.name == cookieName }) else { return nil }
        let value = cookie.value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }

        // "<user_id>::<jwt>" 형식만 유효한 세션으로 간주(로그인 전 임시 쿠키 배제).
        let normalized = value.replacingOccurrences(of: "%3A%3A", with: "::")
        guard normalized.contains("::") else { return nil }
        let userId = normalized.components(separatedBy: "::").first

        return OAuthTokens.session(value, accountId: userId)
    }
}
