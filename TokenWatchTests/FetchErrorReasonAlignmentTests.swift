//
//  FetchErrorReasonAlignmentTests.swift
//  TokenWatchTests
//
//  usage_fetch_error `reason` 분류를 Android와 같은 의미로 맞춘 회귀:
//  토큰 갱신 오류를 통째로 `auth`로 보지 않고 원인별로 나누며(400/401 거부·로그인 없음 → auth,
//  429 → rate_limit, 5xx → http_5xx, 해석 실패 → parse), 보안 저장소를 잠시 읽지 못하면 `credential`.
//  모든 값은 합성 값이다(실제 토큰·키·계정 아님).
//

import Testing
import Foundation
import Security
@testable import TokenWatch

@MainActor
struct FetchErrorReasonAlignmentTests {
    private typealias F = AuthFixtures

    // MARK: OAuth 오류 → 사유

    @Test func 로그인_없음과_refresh_거부는_auth다() {
        #expect(FetchErrorReason(classifying: OAuthError.notAuthenticated) == .auth)
        #expect(FetchErrorReason(classifying: OAuthError.refreshRevoked) == .auth)
    }

    @Test func 토큰_엔드포인트_실패는_원인별로_나눈다() {
        let cases: [(String?, FetchErrorReason)] = [
            ("http_400", .auth), ("http_401", .auth),
            ("invalid_grant", .auth), ("invalid_client", .auth), ("redirect_mismatch", .auth),
            ("http_429", .rateLimit),
            ("http_500", .http5xx), ("http_502", .http5xx), ("http_599", .http5xx),
            ("http_403", .http4xx), ("http_404", .http4xx),
            ("parse", .parse),
            ("http_0", .other), ("http_302", .other), ("http_x", .other), (nil, .other), ("other", .other),
        ]
        for (code, expected) in cases {
            #expect(FetchErrorReason(classifying: OAuthError.refreshFailed("m", code: code)) == expected,
                    "refresh \(code ?? "nil")")
            #expect(FetchErrorReason(classifying: OAuthError.exchangeFailed("m", code: code)) == expected,
                    "exchange \(code ?? "nil")")
        }
    }

    @Test func 업체_장애는_재로그인_문제로_분류하지_않는다() {
        // 실제 갱신 오류 생성 경로(Codex·Grok 토큰 엔드포인트)를 그대로 거친다.
        let busy = CodexOAuth.tokenError(status: 429, body: Data("slow down".utf8), stage: .refresh)
        let down = CodexOAuth.tokenError(status: 503, body: Data("<html>".utf8), stage: .refresh)
        let grokDown = GrokOAuth.tokenError(status: 500, body: Data())
        #expect(FetchErrorReason(classifying: busy) == .rateLimit)
        #expect(FetchErrorReason(classifying: down) == .http5xx)
        #expect(FetchErrorReason(classifying: grokDown) == .http5xx)
        // 영구 거부는 그대로 auth.
        let revoked = CodexOAuth.tokenError(status: 401, body: Data(), stage: .refresh)
        let grokRevoked = GrokOAuth.tokenError(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
        #expect(FetchErrorReason(classifying: revoked) == .auth)
        #expect(FetchErrorReason(classifying: grokRevoked) == .auth)
    }

    @Test func 기존_사용량_오류_분류는_그대로다() {
        #expect(FetchErrorReason(classifying: UsageError.unauthorized) == .auth)
        #expect(FetchErrorReason(classifying: UsageError.rateLimited(nil)) == .rateLimit)
        #expect(FetchErrorReason(classifying: UsageError.http(503, "")) == .http5xx)
        #expect(FetchErrorReason(classifying: UsageError.http(404, "")) == .http4xx)
        #expect(FetchErrorReason(classifying: UsageError.decode("x")) == .parse)
        #expect(FetchErrorReason(classifying: UsageError.noWindows) == .empty)
        #expect(FetchErrorReason(classifying: URLError(.notConnectedToInternet)) == .network)
    }

    // MARK: credential

    @Test func 보안_저장소를_읽지_못하면_credential이다() {
        #expect(FetchErrorReason(classifying: CredentialUnavailable()) == .credential)
        #expect(FetchErrorReason.credential.rawValue == "credential")
        let params = AnalyticsEvent.usageFetchError(provider: .claude, reason: .credential).parameters
        #expect(params["reason"] as? String == "credential")
    }

    @Test func Keychain_읽기_결과를_없음과_읽을_수_없음으로_나눈다() {
        let data = Data("x".utf8) as AnyObject
        guard case .found = Keychain.lookup(status: errSecSuccess, result: data) else {
            Issue.record("found"); return
        }
        guard case .unavailable = Keychain.lookup(status: errSecInteractionNotAllowed, result: nil) else {
            Issue.record("interaction not allowed는 읽을 수 없음"); return
        }
        guard case .missing = Keychain.lookup(status: errSecItemNotFound, result: nil) else {
            Issue.record("item not found는 없음"); return
        }
        // 그 밖의 실패는 기존과 같이 없음으로 본다.
        guard case .missing = Keychain.lookup(status: errSecParam, result: nil) else {
            Issue.record("기타 실패"); return
        }
    }

    @Test func 저장소를_읽지_못하면_로그인_필요가_아니라_credential로_끝나고_토큰은_남는다() async throws {
        let storage = MemoryCredentialStorage(), refresher = ScriptedRefresher()
        let store = TokenStore(storage: storage, refresher: { _, tokens in try await refresher.refresh(tokens) })
        let id = UUID()
        storage.seed(F.oauth(access: "a", refresh: "r", expired: true), for: id)
        storage.readsUnavailable = true

        await #expect(throws: CredentialUnavailable.self) {
            _ = try await store.validTokens(for: id, provider: .claude)
        }
        await #expect(throws: CredentialUnavailable.self) {
            _ = try await store.forceRefresh(for: id, provider: .claude)
        }
        #expect(await refresher.callCount == 0)          // 읽지 못한 채 갱신을 보내지 않는다
        #expect(storage.read(id)?.refreshToken == "r")   // 자격증명은 그대로

        // 다시 읽히면 평소대로 진행한다.
        storage.readsUnavailable = false
        storage.seed(F.oauth(access: "a", refresh: "r", expired: false), for: id)
        #expect(try await store.validTokens(for: id, provider: .claude).accessToken == "a")
    }

    @Test func 저장소가_없으면_기존처럼_로그인_필요다() async {
        let store = TokenStore(storage: MemoryCredentialStorage(), refresher: { _, t in t })
        await #expect(throws: OAuthError.self) {
            _ = try await store.validTokens(for: UUID(), provider: .claude)
        }
    }

    @Test func credential_카드_문구는_재로그인을_권하지_않는다() {
        let ko = L10n(lang: .ko).errCredentialUnavailable
        let en = L10n(lang: .en).errCredentialUnavailable
        #expect(ko == "기기 보안 저장소를 잠시 읽지 못했습니다. 잠시 후 다시 시도해 주세요.")
        #expect(ko != en)
        #expect(!ko.contains("로그인") && !en.lowercased().contains("sign in") && !en.lowercased().contains("log in"))
    }
}
