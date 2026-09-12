//
//  OAuthBrowserLoginTests.swift
//  TokenWatchTests
//
//  외부 브라우저 로그인 경로의 순수 파싱 로직 검증:
//  - ClaudeOAuth.parseManualCode: 사용자가 붙여넣는 문자열의 관용 처리
//  - LoopbackCallbackServer: HTTP 요청 라인 → 콜백 파싱 + state 검증
//

import Testing
import Foundation
@testable import TokenWatch

struct OAuthBrowserLoginTests {
    private let fallback = "state-from-pkce"

    // MARK: parseManualCode

    @Test func 코드와state를_해시로_분리한다() {
        let parsed = ClaudeOAuth.parseManualCode("abc123#xyz789", fallbackState: fallback)
        #expect(parsed?.code == "abc123")
        #expect(parsed?.state == "xyz789")
    }

    @Test func state가_없으면_우리가_만든_값을_쓴다() {
        let parsed = ClaudeOAuth.parseManualCode("abc123", fallbackState: fallback)
        #expect(parsed?.code == "abc123")
        #expect(parsed?.state == fallback)
    }

    @Test func 앞뒤_공백과_줄바꿈을_다듬는다() {
        let parsed = ClaudeOAuth.parseManualCode("  abc123#xyz789\n", fallbackState: fallback)
        #expect(parsed?.code == "abc123")
        #expect(parsed?.state == "xyz789")
    }

    @Test func 콜백_URL을_통째로_붙여넣어도_받는다() {
        let url = "https://console.anthropic.com/oauth/code/callback?code=abc123&state=xyz789"
        let parsed = ClaudeOAuth.parseManualCode(url, fallbackState: fallback)
        #expect(parsed?.code == "abc123")
        #expect(parsed?.state == "xyz789")
    }

    @Test func 빈_문자열은_거부한다() {
        #expect(ClaudeOAuth.parseManualCode("", fallbackState: fallback) == nil)
        #expect(ClaudeOAuth.parseManualCode("   \n ", fallbackState: fallback) == nil)
        #expect(ClaudeOAuth.parseManualCode("#onlystate", fallbackState: fallback) == nil)
    }

    // MARK: LoopbackCallbackServer 파싱

    @Test func 콜백_경로와_state가_맞으면_코드를_뽑는다() {
        let parsed = LoopbackCallbackServer.parseCallback(
            target: "/callback?code=abc123&state=\(fallback)", expectedState: fallback)
        #expect(parsed?.code == "abc123")
        #expect(parsed?.state == fallback)
    }

    @Test func state가_다르면_받지_않는다() {
        // CSRF 방어 — 우리가 시작하지 않은 인가 흐름의 응답은 버린다.
        let parsed = LoopbackCallbackServer.parseCallback(
            target: "/callback?code=abc123&state=attacker", expectedState: fallback)
        #expect(parsed == nil)
    }

    @Test func 다른_경로나_코드_없는_요청은_받지_않는다() {
        #expect(LoopbackCallbackServer.parseCallback(
            target: "/favicon.ico", expectedState: fallback) == nil)
        #expect(LoopbackCallbackServer.parseCallback(
            target: "/callback?state=\(fallback)", expectedState: fallback) == nil)
        #expect(LoopbackCallbackServer.parseCallback(
            target: "/callback?code=&state=\(fallback)", expectedState: fallback) == nil)
        // 에러 리다이렉트(사용자가 승인 거부)에는 code가 없다.
        #expect(LoopbackCallbackServer.parseCallback(
            target: "/callback?error=access_denied&state=\(fallback)", expectedState: fallback) == nil)
    }

    // MARK: 요청 라인 파싱

    @Test func 헤더가_끝나야_요청_라인을_읽는다() {
        let partial = Data("GET /callback?code=a&state=b HTTP/1.1\r\nHost: localhost".utf8)
        #expect(LoopbackCallbackServer.requestLine(in: partial) == nil)

        let complete = Data("GET /callback?code=a&state=b HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        #expect(LoopbackCallbackServer.requestLine(in: complete) == "GET /callback?code=a&state=b HTTP/1.1")
    }

    // MARK: 리스너 통합(실제 소켓 왕복)

    /// 브라우저가 보내는 것과 같은 요청을 루프백으로 실제로 던져 code가 전달되는지 본다.
    @MainActor
    @Test func 루프백_리스너가_콜백을_받아_코드를_넘긴다() async throws {
        let state = "integration-state"
        var received: (code: String, state: String)?
        let server = LoopbackCallbackServer(expectedState: state) { code, s in
            received = (code, s)
        }
        let port = try await server.start()
        defer { server.stop() }
        #expect(port > 0)

        let url = URL(string: "http://127.0.0.1:\(port)/callback?code=integration-code&state=\(state)")!
        let (data, response) = try await URLSession.shared.data(from: url)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: data, encoding: .utf8)?.contains("tokenwatch://login-complete") == true)
        #expect(received?.code == "integration-code")
        #expect(received?.state == state)
    }

    /// state가 다른 요청은 404로 막고 콜백도 호출되지 않아야 한다.
    @MainActor
    @Test func 리스너가_state_불일치_요청을_막는다() async throws {
        var called = false
        let server = LoopbackCallbackServer(expectedState: "right") { _, _ in called = true }
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/callback?code=x&state=wrong")!
        let (_, response) = try await URLSession.shared.data(from: url)

        #expect((response as? HTTPURLResponse)?.statusCode == 404)
        #expect(called == false)
    }

    @Test func GET_요청_라인에서_경로를_뽑는다() {
        #expect(LoopbackCallbackServer.target(ofRequestLine: "GET /callback?code=a HTTP/1.1")
                == "/callback?code=a")
        // POST 등 다른 메서드는 우리 콜백이 아니다.
        #expect(LoopbackCallbackServer.target(ofRequestLine: "POST /callback HTTP/1.1") == nil)
        #expect(LoopbackCallbackServer.target(ofRequestLine: "garbage") == nil)
    }
}
