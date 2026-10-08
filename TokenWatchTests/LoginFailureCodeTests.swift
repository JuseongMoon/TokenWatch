//
//  LoginFailureCodeTests.swift
//  TokenWatchTests
//
//  login_fail 코드 분류(LoginFailureCode)와 진단 보고 본문(LoginFailureReporter.payload) 검증.
//  서버와 같은 분류표를 쓰므로 값이 바뀌면 여기서 드러나야 한다. (네트워크 없이 순수 로직만 본다.)
//

import Testing
import Foundation
@testable import TokenWatch

@MainActor
struct LoginFailureCodeTests {

    private func body(_ json: String) -> Data { Data(json.utf8) }

    private func isValidCode(_ code: String) -> Bool {
        code.range(of: #"\A[a-z0-9_]{1,40}\z"#, options: .regularExpression) != nil
    }

    // MARK: HTTP 응답

    @Test func OAuth_error_필드로_특정_사유를_고른다() {
        #expect(LoginFailureCode.http(status: 400, body: body(#"{"error":"invalid_grant"}"#)) == "invalid_grant")
        #expect(LoginFailureCode.http(status: 401, body: body(#"{"error":"invalid_client"}"#)) == "invalid_client")
        #expect(LoginFailureCode.http(status: 400, body: body(#"{"error":"unauthorized_client"}"#)) == "invalid_client")
        #expect(LoginFailureCode.http(status: 400, body: body(
            #"{"error":"invalid_request","error_description":"Invalid redirect_uri"}"#)) == "redirect_mismatch")
        #expect(LoginFailureCode.http(status: 400, body: body(#"{"error":"redirect_uri_mismatch"}"#)) == "redirect_mismatch")
    }

    @Test func 특정_사유가_아니면_http_상태코드() {
        #expect(LoginFailureCode.http(status: 400, body: body(#"{"error":"invalid_request"}"#)) == "http_400")
        #expect(LoginFailureCode.http(status: 403, body: body("<html>Forbidden</html>")) == "http_403")
        #expect(LoginFailureCode.http(status: 503, body: Data()) == "http_503")
        // JSON이 아니어도 invalid_grant 문자열은 기존 분류와 같이 본다.
        #expect(LoginFailureCode.http(status: 400, body: body("error=invalid_grant")) == "invalid_grant")
    }

    // MARK: 에러 → 코드

    @Test func OAuthError는_실린_코드를_쓴다() {
        #expect(LoginFailureCode.from(OAuthError.exchangeFailed("x", code: "http_500")) == "http_500")
        #expect(LoginFailureCode.from(OAuthError.refreshFailed("x", code: "parse")) == "parse")
        #expect(LoginFailureCode.from(OAuthError.refreshRevoked) == "invalid_grant")
        #expect(LoginFailureCode.from(OAuthError.exchangeFailed("x")) == "other")
        #expect(LoginFailureCode.from(OAuthError.notAuthenticated) == "other")
    }

    @Test func 폴링_로그인_에러() {
        #expect(LoginFailureCode.from(DeviceFlowError.expired) == "expired")
        #expect(LoginFailureCode.from(DeviceFlowError.denied) == "denied")
        #expect(LoginFailureCode.from(DeviceFlowError.timedOut) == "timed_out")
        #expect(LoginFailureCode.from(DeviceFlowError.http("x", code: "unavailable")) == "unavailable")
        #expect(LoginFailureCode.from(DeviceFlowError.http("x", code: "malformed")) == "malformed")
        #expect(LoginFailureCode.oauthError("incorrect_client_credentials") == "invalid_client")
        #expect(LoginFailureCode.oauthError("device_flow_disabled") == nil)
    }

    @Test func API_키_확인_에러() {
        #expect(LoginFailureCode.from(KimiKeyError.invalid) == "http_401")
        #expect(LoginFailureCode.from(UsageError.http(403, "body")) == "http_403")
        #expect(LoginFailureCode.from(UsageError.rateLimited(nil)) == "http_429")
        #expect(LoginFailureCode.from(UsageError.decode("x")) == "parse")
    }

    @Test func 네트워크_에러를_세_갈래로_나눈다() {
        #expect(LoginFailureCode.from(URLError(.notConnectedToInternet)) == "network_offline")
        #expect(LoginFailureCode.from(URLError(.networkConnectionLost)) == "network_offline")
        #expect(LoginFailureCode.from(URLError(.timedOut)) == "network_timeout")
        #expect(LoginFailureCode.from(URLError(.cannotFindHost)) == "network_other")
    }

    @Test func 응답_해석_실패는_parse() {
        let jsonError: Error
        do {
            _ = try JSONSerialization.jsonObject(with: Data("not json".utf8))
            Issue.record("JSON 해석이 실패해야 함")
            return
        } catch {
            jsonError = error
        }
        #expect(LoginFailureCode.from(jsonError) == "parse")
    }

    @Test func 웹뷰_실패는_부호_없는_NSError_코드() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(LoginFailureCode.webview(error) == "webview_1009")
    }

    // MARK: 정규화

    @Test func 정규화는_규칙에_맞는_코드만_남긴다() {
        #expect(LoginFailureCode.sanitized("auth_session_-1") == "auth_session__1")
        #expect(LoginFailureCode.sanitized("OAuthError") == "oautherror")
        #expect(LoginFailureCode.sanitized("") == "other")
        #expect(LoginFailureCode.sanitized(String(repeating: "a", count: 60)).count == 40)
        for code in ["http_401", "invalid_grant", "webview_1009", "network_offline", "keychain_save"] {
            #expect(isValidCode(LoginFailureCode.sanitized(code)))
            #expect(LoginFailureCode.sanitized(code) == code)
        }
    }

    // MARK: 진단 보고 본문

    @Test func 보고_본문은_계약된_키만_담는다() throws {
        let info: [String: Any] = ["CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "42"]
        let payload = try #require(LoginFailureReporter.payload(provider: .claude, stage: .exchange,
                                                                code: "invalid_grant", info: info))
        #expect(payload == .init(platform: "ios", appVersion: "1.2.0", build: "42", provider: "claude",
                                 authKind: "oauth_browser", stage: "exchange", code: "invalid_grant"))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        #expect(Set((json ?? [:]).keys) ==
                ["platform", "appVersion", "build", "provider", "authKind", "stage", "code"])
    }

    @Test func 버전_형식이_틀리면_보내지_않는다() {
        let bad: [String: Any] = ["CFBundleShortVersionString": "1.2 beta", "CFBundleVersion": "42"]
        #expect(LoginFailureReporter.payload(provider: .kimi, stage: .apiKeyEntry, code: "http_401", info: bad) == nil)
        #expect(LoginFailureReporter.payload(provider: .kimi, stage: .apiKeyEntry, code: "http_401", info: [:]) == nil)
        #expect(LoginFailureReporter.isValidVersion("1.2.0"))
        #expect(!LoginFailureReporter.isValidVersion("1.2.0\n"))
        #expect(!LoginFailureReporter.isValidVersion(".1"))
    }
}
