//
//  GrokAuth.swift
//  TokenWatch
//
//  Grok(grok.com) 로그인 — WKWebView로 로그인시킨 뒤 세션 쿠키를 캡처한다.
//  인증 쿠키 이름이 공개돼 있지 않아, 인프라/봇관리 쿠키를 제외한 세션 쿠키가
//  나타나면 grok.com 쿠키 전체를 Cookie 헤더 문자열로 저장한다.
//
//  ⚠️ 로그인 판정(세션 쿠키 등장)과 사용량 엔드포인트(gRPC-web)는 리버스 엔지니어링
//     기반이라 벤더 변경에 취약하다. 정확한 쿠키명은 실제 로그인으로 확인해 좁힐 수 있다.
//

import Foundation

enum GrokAuth {
    static let loginURL = URL(string: "https://grok.com/")!

    /// 로그인 전에도 존재하는 인프라/봇관리 쿠키 — 세션 판정에서 제외.
    static let infraCookies: Set<String> = [
        "grok_device_id", "__cf_bm", "cf_clearance", "_cfuvid",
    ]

    /// grok.com 세션 쿠키(인프라 제외)가 잡히면 쿠키 전체를 자격증명으로 만든다.
    static func sessionProbe(_ cookies: [HTTPCookie]) -> OAuthTokens? {
        let grok = cookies.filter { $0.domain.contains("grok.com") && !$0.value.isEmpty }
        // 로그인 세션으로 볼 만한 쿠키(인프라 외)가 하나라도 있어야 로그인 완료로 간주.
        let hasSession = grok.contains { !infraCookies.contains($0.name) }
        guard hasSession else { return nil }

        let header = grok.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return OAuthTokens.session(header)
    }
}
