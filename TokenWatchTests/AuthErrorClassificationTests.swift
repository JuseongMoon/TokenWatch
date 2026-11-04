//
//  AuthErrorClassificationTests.swift
//  TokenWatchTests
//
//  A2: Codex 토큰 엔드포인트 오류의 영구/일시 분류(refresh와 인가 코드 교환 단계 구분 포함).
//  A6: OpenRouter `/credits`의 키 종류·권한 오류 안내와 잔액 의미 유지.
//  R4: 폼 본문 인코딩이 `+`·공백·`&`·`=`·`%`·유니코드를 서버 폼 디코딩 뒤에도 그대로 보존.
//  모든 입력은 합성 값이다.
//

import Testing
import Foundation
@testable import TokenWatch

@MainActor
struct AuthErrorClassificationTests {

    // MARK: A2 — Codex refresh 영구 실패

    nonisolated private static let permanentCodes = ["invalid_grant", "refresh_token_expired",
                                         "refresh_token_reused", "refresh_token_invalidated"]

    /// 세 가지 응답 형태: 문자열 error, 중첩 error.code, 최상위 code.
    private static func bodies(_ code: String) -> [Data] {
        [
            Data(#"{"error":"\#(code)","error_description":"synthetic"}"#.utf8),
            Data(#"{"error":{"code":"\#(code)","message":"synthetic"}}"#.utf8),
            Data(#"{"code":"\#(code)","message":"synthetic"}"#.utf8),
        ]
    }

    @Test(arguments: permanentCodes)
    func 알려진_영구_오류는_세_형태_모두_400_401에서_재로그인으로_분류된다(_ code: String) {
        for body in Self.bodies(code) {
            for status in [400, 401] {
                #expect(CodexOAuth.errorCode(in: body) == code)
                #expect(CodexOAuth.isPermanentRefreshFailure(status: status, body: body), "\(status) \(code)")
                guard case .refreshRevoked = CodexOAuth.tokenError(status: status, body: body, stage: .refresh) else {
                    Issue.record("영구 오류가 refreshRevoked가 아님: \(status) \(code)")
                    continue
                }
            }
        }
    }

    /// 공식 Codex CLI 규칙의 경계: 401은 코드와 무관하게, 영구 코드 3종은 상태와 무관하게(대소문자 무시),
    /// 400 + invalid_grant는 영구. 나머지는 일시 실패.
    @Test func 공식_Codex_CLI_규칙대로_영구_실패를_가린다() {
        let permanent: [(Int, Data)] = [
            (401, Data(#"{"error":"something_unknown"}"#.utf8)),          // 401 미지 코드
            (401, Data("not json".utf8)),                                  // 401 본문 해석 불가
            (401, Data(#"{"error":{"message":"no code"}}"#.utf8)),
            (403, Data(#"{"error":"refresh_token_reused"}"#.utf8)),        // 403 + 영구 코드
            (500, Data(#"{"code":"refresh_token_expired"}"#.utf8)),        // 상태 무관
            (400, Data(#"{"error":"REFRESH_TOKEN_INVALIDATED"}"#.utf8)),   // 대문자 코드
            (400, Data(#"{"error":{"code":"Refresh_Token_Reused"}}"#.utf8)),
            (400, Data(#"{"error":"INVALID_GRANT"}"#.utf8)),               // 400 + invalid_grant(대문자)
        ]
        for (status, body) in permanent {
            #expect(CodexOAuth.isPermanentRefreshFailure(status: status, body: body),
                    "\(status) \(String(decoding: body, as: UTF8.self))")
            guard case .refreshRevoked = CodexOAuth.tokenError(status: status, body: body, stage: .refresh) else {
                Issue.record("영구 실패가 refreshRevoked가 아님: \(status)")
                continue
            }
        }
    }

    @Test func 일시_오류와_미지의_오류는_자격증명을_보존하는_실패로_둔다() {
        let cases: [(Int, Data)] = [
            (429, Data(#"{"error":"rate_limited"}"#.utf8)),
            (500, Data(#"{"error":"server_error"}"#.utf8)),
            (500, Data(#"{"error":"invalid_grant"}"#.utf8)),        // invalid_grant는 400일 때만 영구
            (503, Data("<html>unavailable</html>".utf8)),
            (400, Data(#"{"error":"invalid_request"}"#.utf8)),      // 400 invalid_request
            (403, Data(#"{"error":"forbidden"}"#.utf8)),            // 미지 코드
            (400, Data("not json at all".utf8)),                    // 잘못된 JSON
            (400, Data(#"{"error":{"message":"no code"}}"#.utf8)),
        ]
        for (status, body) in cases {
            #expect(!CodexOAuth.isPermanentRefreshFailure(status: status, body: body), "\(status)")
            guard case .refreshFailed = CodexOAuth.tokenError(status: status, body: body, stage: .refresh) else {
                Issue.record("일시 오류가 refreshFailed가 아님: \(status)")
                continue
            }
        }
    }

    @Test func 인가_코드_교환_단계는_기존_분류를_유지한다() {
        // 만료·재사용된 인가 코드: 재로그인 안내(교환 단계 오류는 TokenStore를 거치지 않는다).
        let expiredCode = Data(#"{"error":"invalid_grant"}"#.utf8)
        guard case .refreshRevoked = CodexOAuth.tokenError(status: 400, body: expiredCode, stage: .exchange) else {
            Issue.record("교환 단계 invalid_grant 분류가 바뀌었다"); return
        }
        // refresh 전용 코드는 교환 단계에서 영구 refresh 실패로 승격하지 않는다.
        let refreshOnly = Data(#"{"error":"refresh_token_expired"}"#.utf8)
        guard case .exchangeFailed(_, let code) = CodexOAuth.tokenError(status: 400, body: refreshOnly,
                                                                        stage: .exchange) else {
            Issue.record("교환 단계 오류가 exchangeFailed가 아님"); return
        }
        // 분석 코드는 기존 분류표 값(원문 아님).
        #expect(code == "http_400")
    }

    @Test func refresh_실패의_분석_코드에는_원문이_섞이지_않는다() {
        let body = Data(#"{"error":"server_error","error_description":"secret@example.com token=abc"}"#.utf8)
        guard case .refreshFailed(_, let code) = CodexOAuth.tokenError(status: 500, body: body, stage: .refresh) else {
            Issue.record("분류 실패"); return
        }
        #expect(code == "http_500")
        #expect(LoginFailureCode.from(OAuthError.refreshRevoked) == "invalid_grant")
    }

    // MARK: A6 — OpenRouter 관리 키

    @Test func OpenRouter_403은_관리_키_안내로_401은_키_거부로_안내한다() {
        let forbidden = OpenRouterUsageClient.statusError(403, retryAfter: nil,
                                                          body: Data(#"{"error":{"code":403,"message":"Only management keys can perform this operation"}}"#.utf8))
        guard case .keyRejected(403, let message403)? = forbidden else {
            Issue.record("403 분류 실패"); return
        }
        #expect(message403 == L10n(lang: currentLang()).errOpenRouterNeedsManagementKey)
        #expect(forbidden?.errorDescription == message403)

        let unauthorized = OpenRouterUsageClient.statusError(401, retryAfter: nil, body: Data())
        guard case .keyRejected(401, let message401)? = unauthorized else {
            Issue.record("401 분류 실패"); return
        }
        #expect(message401 != message403)
    }

    @Test func OpenRouter_워크스페이스_범위_403도_잔액이나_인증만료로_뭉개지_않는다() {
        // 관리 키라도 워크스페이스 전용이면 계정 단위 조회가 403일 수 있다 — 같은 안내로 권한 조건을 알린다.
        let error = OpenRouterUsageClient.statusError(403, retryAfter: nil,
                                                      body: Data(#"{"error":{"code":403,"message":"workspace scope"}}"#.utf8))
        #expect(FetchErrorReason(classifying: error!) == .http4xx)   // 기존 분석 분류 유지
        #expect(LoginFailureCode.from(error!) == "http_403")
        if case .unauthorized? = error { Issue.record("403이 강제 갱신 경로로 가면 안 된다") }
    }

    @Test func OpenRouter_429와_5xx는_기존_처리를_유지한다() {
        guard case .rateLimited? = OpenRouterUsageClient.statusError(429, retryAfter: "30", body: Data()) else {
            Issue.record("429"); return
        }
        guard case .http(502, _)? = OpenRouterUsageClient.statusError(502, retryAfter: nil, body: Data()) else {
            Issue.record("5xx"); return
        }
        #expect(OpenRouterUsageClient.statusError(200, retryAfter: nil, body: Data()) == nil)
        let reason = FetchErrorReason(classifying: UsageError.keyRejected(status: 401, message: "x"))
        #expect(reason == .auth)
    }

    @Test func OpenRouter_정상_응답은_계정_잔액을_그대로_보여준다() throws {
        let body = Data(#"{"data":{"total_credits":12.5,"total_usage":2.25}}"#.utf8)
        let windows = try OpenRouterUsageClient.windows(from: body)
        #expect(windows.count == 1)
        #expect(windows.first?.balanceRemaining == 10.25)
        #expect(windows.first?.balanceTotal == 12.5)
    }

    @Test func OpenRouter_필드가_빠진_응답은_잔액_0으로_표시하지_않는다() {
        #expect(throws: UsageError.self) {
            try OpenRouterUsageClient.windows(from: Data(#"{"data":{}}"#.utf8))
        }
        #expect(throws: UsageError.self) {
            try OpenRouterUsageClient.windows(from: Data(#"{"error":{"code":403,"message":"x"}}"#.utf8))
        }
    }

    @Test func OpenRouter_키_입력_안내와_발급_링크가_관리_키를_가리킨다() {
        let ko = L10n(lang: .ko), en = L10n(lang: .en)
        #expect(ko.apiKeyHint(provider: .openrouter)?.contains("관리 키") == true)
        #expect(en.apiKeyHint(provider: .openrouter)?.contains("Management Key") == true)
        #expect(ko.errOpenRouterNeedsManagementKey.contains("관리 키"))
        #expect(en.errOpenRouterNeedsManagementKey.contains("Management Key"))
        #expect(ko.errOpenRouterNeedsManagementKey != en.errOpenRouterNeedsManagementKey)
        #expect(ko.errOpenRouterKeyRejected.contains("401") && en.errOpenRouterKeyRejected.contains("401"))
        #expect(AgentProvider.openrouter.apiKeyURL?.path == "/settings/management-keys")
    }

    // MARK: R4 — 폼 본문 인코딩

    /// 서버 쪽 `application/x-www-form-urlencoded` 디코딩(`+` → 공백, 그다음 퍼센트 디코딩).
    private func formDecode(_ body: Data) -> [String: String] {
        var out: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            }
            out[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return out
    }

    @Test func 폼_본문은_특수문자를_서버_디코딩_뒤에도_보존한다() {
        let values = ["a+b/c=d&e f", "100%", "x y+z", "토큰-ü-✓", "~._-", ""]
        for value in values {
            let decoded = formDecode(FormURLEncoding.body([("code", value), ("grant_type", "authorization_code")]))
            #expect(decoded["code"] == value, "\(value)")
            #expect(decoded["grant_type"] == "authorization_code")
        }
    }

    @Test func Claude_Codex_Copilot_폼과_Grok_인코더가_같은_규칙을_쓴다() {
        let params = ["code": "a+b", "state": "s t", "redirect_uri": "http://localhost:1/callback"]
        let sorted = params.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        let expected = GrokOAuth.formBody(sorted)
        #expect(ClaudeOAuth.form(params) == expected)
        #expect(CodexOAuth.form(params) == expected)
        #expect(CopilotDeviceFlow.form(params) == expected)
        #expect(!String(decoding: expected, as: UTF8.self).contains("+"))
    }
}
