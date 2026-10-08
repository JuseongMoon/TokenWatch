//
//  GrokOAuthTests.swift
//  TokenWatchTests
//
//  Grok OAuth 순수 로직 검증: authorize URL, 토큰 응답 매핑(이메일·만료·회전), 오류 분류, 폼 인코딩.
//  (네트워크 없이 결정적으로 도는 부분만 본다. 실제 로그인은 실기기 확인 대상.)
//

import Testing
import Foundation
@testable import TokenWatch

@MainActor
struct GrokOAuthTests {

    private func components(_ url: URL) -> URLComponents? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)
    }

    private func query(_ url: URL) -> [String: String] {
        let items = components(url)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    /// payload만 의미 있는 가짜 id_token(서명을 검증하지 않으므로 헤더·서명 자리는 아무 값).
    private func idToken(_ payload: [String: String]) -> String {
        let json = try! JSONSerialization.data(withJSONObject: payload)
        return "e30.\(json.base64URLEncodedString()).sig"
    }

    @Test func 인가_URL은_CLI와_같은_파라미터로_만든다() {
        let pkce = PKCE()
        let redirect = GrokOAuth.loopbackRedirectURI(port: 54321)
        let url = ProviderAuth.authorizeURL(.grok, pkce: pkce, redirect: redirect)
        #expect(components(url)?.host == "auth.x.ai")
        #expect(components(url)?.path == "/oauth2/authorize")
        let q = query(url)
        #expect(q["response_type"] == "code")
        #expect(q["client_id"] == GrokOAuth.clientID)
        #expect(q["redirect_uri"] == "http://127.0.0.1:54321/callback")
        #expect(q["scope"] == "openid profile email offline_access grok-cli:access")
        #expect(q["code_challenge"] == pkce.challenge)
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["state"] == pkce.state)
        #expect(q["nonce"]?.isEmpty == false)
        // 분석 집계용 referrer는 보내지 않는다. Claude 전용 `code=true`도 섞이면 안 된다.
        #expect(q["referrer"] == nil)
        #expect(q["code"] == nil)
    }

    @Test func Grok은_루프백_redirect를_쓰고_코드_붙여넣기_폴백이_없다() {
        #expect(AgentProvider.grok.authKind == .oauthBrowser)
        #expect(ProviderAuth.loopbackRedirectURI(.grok, port: 8080) == "http://127.0.0.1:8080/callback")
        #expect(ProviderAuth.manualCodeRedirect(.grok) == nil)
        #expect(L10n(lang: .ko).browserSheetIntro(provider: AgentProvider.grok.displayName).contains("Grok"))
    }

    @Test func 토큰_응답에서_이메일과_만료를_읽는다() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let json = """
        {"access_token":"at-1","refresh_token":"rt-1","expires_in":3600,"token_type":"Bearer",
         "id_token":"\(idToken(["sub": "user-1", "email": "grok@example.com"]))"}
        """
        let tokens = try GrokOAuth.tokens(from: Data(json.utf8), previous: nil, now: now)
        #expect(tokens.accessToken == "at-1")
        #expect(tokens.refreshToken == "rt-1")
        #expect(tokens.expiresAt == now.addingTimeInterval(3600))
        #expect(tokens.accountEmail == "grok@example.com")
        #expect(tokens.scopes == GrokOAuth.scopes)
    }

    /// 갱신 응답에 새 refresh_token·id_token이 비어 있으면 이전 값(과 이메일·플랜)을 유지한다.
    @Test func 갱신_응답에_없는_값은_이전_값을_유지한다() throws {
        let previous = OAuthTokens(accessToken: "old", refreshToken: "rt-old", expiresAt: nil,
                                   scopes: GrokOAuth.scopes, accountEmail: "grok@example.com",
                                   plan: "SuperGrok", idToken: "not-a-jwt")
        let json = #"{"access_token":"new","refresh_token":"","expires_in":600}"#
        let tokens = try GrokOAuth.tokens(from: Data(json.utf8), previous: previous)
        #expect(tokens.accessToken == "new")
        #expect(tokens.refreshToken == "rt-old")
        #expect(tokens.idToken == "not-a-jwt")
        #expect(tokens.accountEmail == "grok@example.com")
        #expect(tokens.plan == "SuperGrok")
    }

    @Test func 빈_access_token은_거부한다() {
        #expect(throws: OAuthError.self) {
            try GrokOAuth.tokens(from: Data(#"{"access_token":""}"#.utf8), previous: nil)
        }
    }

    @Test func invalid_grant는_재로그인이_필요한_거부로_분류한다() {
        let body = Data(#"{"error":"invalid_grant","error_description":"refresh token reused"}"#.utf8)
        for status in [400, 401] {
            guard case .refreshRevoked = GrokOAuth.tokenError(status: status, body: body) else {
                Issue.record("HTTP \(status) + invalid_grant는 refreshRevoked여야 함")
                continue
            }
        }
        guard case .refreshFailed = GrokOAuth.tokenError(status: 500, body: Data("oops".utf8)) else {
            Issue.record("5xx는 일시 실패(refreshFailed)여야 함")
            return
        }
    }

    /// refresh token에 `+`·`/`·`=`·`&`·공백이 있어도 서버가 같은 값으로 읽도록 엄격하게 인코딩한다.
    @Test func 폼_본문은_예약_문자를_모두_인코딩한다() {
        let body = GrokOAuth.formBody([("grant_type", "refresh_token"), ("refresh_token", "a+b/c=d&e f")])
        #expect(String(data: body, encoding: .utf8)
                == "grant_type=refresh_token&refresh_token=a%2Bb%2Fc%3Dd%26e%20f")
    }
}
