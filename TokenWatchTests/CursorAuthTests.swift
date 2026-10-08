//
//  CursorAuthTests.swift
//  TokenWatchTests
//
//  Cursor 로그인 순수 로직 검증: 로그인 주소(handshake), auth/poll 판정(SDK 규칙), 폴링 요청 형식,
//  세션 쿠키·JWT 파싱. (실제 로그인·폴링은 실기기 확인 대상.)
//

import Testing
import Foundation
import CryptoKit
@testable import TokenWatch

@MainActor
struct CursorAuthTests {

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    /// payload만 의미 있는 가짜 JWT(서명을 검증하지 않으므로 헤더·서명 자리는 아무 값).
    private func jwt(_ payload: [String: Any]) -> String {
        let json = try! JSONSerialization.data(withJSONObject: payload)
        return "e30.\(json.base64URLEncodedString()).sig"
    }

    @Test func 로그인_주소는_SDK와_같은_handshake를_쓴다() {
        let pkce = PKCE()
        let handshake = CursorAuth.makeHandshake(pkce: pkce, uuid: "11111111-2222-4333-8444-555555555555")
        let comps = URLComponents(url: handshake.loginURL, resolvingAgainstBaseURL: false)
        #expect(comps?.host == "cursor.com")
        #expect(comps?.path == "/loginDeepControl")
        let q = query(handshake.loginURL)
        // challenge = base64url(SHA-256(verifier "문자열")) — 원시 바이트가 아니다.
        let expected = Data(SHA256.hash(data: Data(pkce.verifier.utf8))).base64URLEncodedString()
        #expect(q["challenge"] == expected)
        #expect(q["uuid"] == "11111111-2222-4333-8444-555555555555")
        #expect(q["mode"] == "login")
        #expect(q["redirectTarget"] == "cli")
        #expect(handshake.verifier == pkce.verifier)
        // verifier는 로그인 주소에 싣지 않는다.
        #expect(q["verifier"] == nil)
    }

    @Test func 폴링_로그인은_코드_없이_로그인_페이지만_연다() async throws {
        #expect(AgentProvider.cursor.authKind == .oauthDeviceFlow)
        let login = try await ProviderAuth.startPollingLogin(.cursor)
        #expect(login.userCode == nil)
        #expect(login.verificationURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.host }
                == "cursor.com")
    }

    // MARK: auth/poll 판정 (SDK pollForLoginTokens 규칙)

    @Test func 대기_중_404와_POST_경로_없음을_구분한다() {
        let notFound = Data("Not found".utf8)
        #expect(CursorAuth.pollOutcome(status: 404, body: notFound, usingGET: false,
                                       checkedPendingBody: false) == .pending)
        // POST 경로가 없는 서버는 404 본문이 다르다 → GET으로 전환.
        let postMissing = Data(#"{"message":"Route POST:/auth/poll not found"}"#.utf8)
        #expect(CursorAuth.pollOutcome(status: 404, body: postMissing, usingGET: false,
                                       checkedPendingBody: false) == .switchToGET)
        // GET 경로도 없으면 중단.
        let getMissing = Data(#"{"message":"Route GET:/auth/poll not found"}"#.utf8)
        #expect(CursorAuth.pollOutcome(status: 404, body: getMissing, usingGET: true,
                                       checkedPendingBody: false) == .unavailable)
        // 한 번 확인한 뒤의 404는 본문과 무관하게 대기.
        #expect(CursorAuth.pollOutcome(status: 404, body: postMissing, usingGET: false,
                                       checkedPendingBody: true) == .pending)
    }

    @Test func 승인되면_토큰을_받고_이상한_응답은_거부한다() {
        let ok = Data(#"{"accessToken":"at","refreshToken":"rt","authId":"a"}"#.utf8)
        #expect(CursorAuth.pollOutcome(status: 200, body: ok, usingGET: false,
                                       checkedPendingBody: true) == .tokens("at"))
        let missingRefresh = Data(#"{"accessToken":"at"}"#.utf8)
        #expect(CursorAuth.pollOutcome(status: 200, body: missingRefresh, usingGET: false,
                                       checkedPendingBody: true) == .malformed)
        for status in [400, 401, 403, 410] {
            #expect(CursorAuth.pollOutcome(status: status, body: Data(), usingGET: false,
                                           checkedPendingBody: true) == .denied)
        }
        #expect(CursorAuth.pollOutcome(status: 502, body: Data(), usingGET: false,
                                       checkedPendingBody: true) == .retry)
    }

    /// POST는 verifier를 본문에 싣고(주소·접근 로그에 남지 않게), GET 폴백만 쿼리로 보낸다.
    @Test func 폴링_요청은_POST_본문이_기본이고_GET은_쿼리로_보낸다() throws {
        let handshake = CursorAuth.makeHandshake(pkce: PKCE(), uuid: "u-1")
        let post = CursorAuth.pollRequest(handshake, useGET: false)
        #expect(post.httpMethod == "POST")
        #expect(post.url?.query == nil)
        let body = try JSONSerialization.jsonObject(with: post.httpBody ?? Data()) as? [String: String]
        #expect(body?["uuid"] == "u-1")
        #expect(body?["verifier"] == handshake.verifier)

        let get = CursorAuth.pollRequest(handshake, useGET: true)
        #expect(get.httpMethod == "GET")
        #expect(get.url.map { query($0) }?["verifier"] == handshake.verifier)
    }

    // MARK: 세션 쿠키 · JWT

    @Test func 세션_쿠키는_JWT_sub의_마지막_조각과_토큰을_잇는다() {
        let token = jwt(["sub": "auth0|user_01ABCDEF", "exp": 1_800_000_000])
        #expect(CursorAuth.userID(fromJWT: token) == "user_01ABCDEF")
        #expect(CursorAuth.expiry(fromJWT: token) == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(CursorAuth.cookieHeader(userID: "user_01ABCDEF", accessToken: token)
                == "WorkosCursorSessionToken=user_01ABCDEF%3A%3A\(token)")
        // 저장된 자격증명에 사용자 id가 없어도 JWT에서 다시 뽑는다.
        let tokens = OAuthTokens(accessToken: token, refreshToken: nil, expiresAt: nil, scopes: [],
                                 accountEmail: nil, plan: nil)
        #expect(CursorAuth.cookieHeader(for: tokens) == "WorkosCursorSessionToken=user_01ABCDEF%3A%3A\(token)")
        #expect(CursorAuth.userID(fromJWT: "not-a-jwt") == nil)
    }

    @Test func 로그인_자격증명은_refresh_없이_만료와_사용자_id를_담는다() {
        let token = jwt(["sub": "google-oauth2|user_9", "exp": 1_800_000_000])
        let tokens = CursorAuth.credential(accessToken: token, userID: "user_9", email: "c@example.com")
        #expect(tokens.refreshToken == nil)
        #expect(tokens.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(tokens.accountId == "user_9")
        #expect(tokens.accountEmail == "c@example.com")
    }
}
