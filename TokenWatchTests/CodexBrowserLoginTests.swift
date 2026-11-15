//
//  CodexBrowserLoginTests.swift
//  TokenWatchTests
//
//  Codex 로그인을 웹뷰에서 인증 시트 + 고정 루프백(`localhost:1455/auth/callback`)으로 옮긴 회귀:
//  등록된 redirect 그대로 쓰기, 고정 포트·경로 리스너(IPv4·IPv6), 포트 점유 시 `loopback_port_in_use`,
//  코드 붙여넣기 폴백 없음, 분석 auth_kind. 소켓 테스트는 1455가 아닌 포트로 한다(기기의 다른 앱과 겹치지 않게).
//  단, 코디네이터의 포트 점유 경로만 실제 1455를 먼저 쥐고 확인한다.
//

import Testing
import Foundation
@testable import TokenWatch

@MainActor
struct CodexBrowserLoginTests {
    private let state = "expected-state"

    // MARK: 방식·redirect

    @Test func Codex는_인증_시트_방식이고_분석값은_oauth_browser다() {
        #expect(AgentProvider.codex.authKind == .oauthBrowser)
        #expect(AnalyticsEvent.authKindTag(.codex) == "oauth_browser")
        let start = AnalyticsEvent.loginStart(provider: .codex).parameters
        #expect(start["auth_kind"] as? String == "oauth_browser")
    }

    @Test func Codex_redirect는_포트와_무관하게_등록된_주소_그대로다() {
        for port: UInt16 in [0, 1234, 1455, 54321] {
            #expect(ProviderAuth.loopbackRedirectURI(.codex, port: port) == "http://localhost:1455/auth/callback")
        }
        #expect(CodexOAuth.redirectURI == "http://localhost:1455/auth/callback")
        #expect(ProviderAuth.loopbackPort(.codex) == 1455)
        #expect(ProviderAuth.loopbackCallbackPath(.codex) == "/auth/callback")
        // 다른 provider는 임의 포트·기본 경로 그대로.
        for p in AgentProvider.allCases where p != .codex {
            #expect(ProviderAuth.loopbackPort(p) == nil, "\(p)")
            #expect(ProviderAuth.loopbackCallbackPath(p) == "/callback", "\(p)")
        }
    }

    @Test func Codex_authorize_URL은_등록된_redirect와_CLI_파라미터를_보낸다() throws {
        let pkce = PKCE()
        let redirect = try #require(ProviderAuth.loopbackRedirectURI(.codex, port: 1455))
        let url = ProviderAuth.authorizeURL(.codex, pkce: pkce, redirect: redirect)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        #expect(url.host == "auth.openai.com")
        #expect(value("redirect_uri") == "http://localhost:1455/auth/callback")
        #expect(value("client_id") == CodexOAuth.clientID)
        #expect(value("state") == pkce.state)
        #expect(value("code_challenge") == pkce.challenge)
        #expect(value("code_challenge_method") == "S256")
        #expect(value("codex_cli_simplified_flow") == "true")
    }

    @Test func Codex에는_코드_붙여넣기_폴백이_없다() {
        #expect(ProviderAuth.manualCodeRedirect(.codex) == nil)
        // 폴백이 없으니 로그인 창 실패 안내도 코드 입력을 권하지 않는다.
        let message = L10n(lang: .ko).browserSessionFailed(manualFallback: ProviderAuth.manualCodeRedirect(.codex) != nil)
        #expect(!message.contains("코드"))
    }

    // MARK: 콜백 경로

    @Test func Codex_경로의_콜백만_받는다() {
        let path = CodexOAuth.callbackPath
        #expect(LoopbackCallbackServer.parseCallbackResult(
            target: "/auth/callback?code=abc&state=\(state)", expectedState: state, callbackPath: path)
                == .code("abc", state: state))
        #expect(LoopbackCallbackServer.parseCallbackResult(
            target: "/auth/callback?error=access_denied&state=\(state)", expectedState: state, callbackPath: path)
                == .oauthError("access_denied", state: state))
        // 기본 경로(/callback)나 다른 state는 받지 않는다.
        #expect(LoopbackCallbackServer.parseCallbackResult(
            target: "/callback?code=abc&state=\(state)", expectedState: state, callbackPath: path) == nil)
        #expect(LoopbackCallbackServer.parseCallbackResult(
            target: "/auth/callback?code=abc&state=other", expectedState: state, callbackPath: path) == nil)
        // 기본 경로 리스너(Claude·Grok)는 기존과 같다.
        #expect(LoopbackCallbackServer.parseCallbackResult(
            target: "/auth/callback?code=abc&state=\(state)", expectedState: state) == nil)
    }

    // MARK: 고정 포트 리스너(실제 소켓, 1455 아님)

    /// 비어 있는 루프백 포트 하나를 얻는다(임의 포트로 띄웠다 닫는다).
    private func freePort() async throws -> UInt16 {
        let probe = LoopbackCallbackServer(expectedState: state) { _ in }
        let port = try await probe.start()
        probe.stop()
        try await Task.sleep(for: .milliseconds(50))
        return port
    }

    @Test func 고정_포트로_띄우면_그_포트의_IPv4와_IPv6에서_콜백을_받는다() async throws {
        let port = try await freePort()
        for host in ["127.0.0.1", "[::1]"] {
            var outcomes: [LoopbackOutcome] = []
            let server = LoopbackCallbackServer(expectedState: state, port: port,
                                                callbackPath: CodexOAuth.callbackPath) { outcomes.append($0) }
            let bound = try await server.start()
            #expect(bound == port)
            let url = URL(string: "http://\(host):\(port)/auth/callback?code=c&state=\(state)")!
            let (_, response) = try await URLSession.shared.data(from: url, delegate: NoRedirect())
            #expect((response as? HTTPURLResponse)?.statusCode == 302, "\(host)")
            await eventually { !outcomes.isEmpty }
            #expect(outcomes == [.code("c", state: state)], "\(host)")
            server.stop()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func 고정_포트를_이미_누가_쓰면_포트_점유로_실패한다() async throws {
        let holder = LoopbackCallbackServer(expectedState: "holder") { _ in }
        let port = try await holder.start()
        defer { holder.stop() }

        let server = LoopbackCallbackServer(expectedState: state, port: port,
                                            callbackPath: CodexOAuth.callbackPath) { _ in }
        await #expect(throws: LoopbackListenError.portInUse) { _ = try await server.start() }
        server.stop()
    }

    @Test func 콜백을_처리한_고정_포트는_곧바로_다시_띄울_수_있다() async throws {
        let port = try await freePort()
        let first = LoopbackCallbackServer(expectedState: state, port: port,
                                           callbackPath: CodexOAuth.callbackPath) { _ in }
        _ = try await first.start()
        let url = URL(string: "http://127.0.0.1:\(port)/auth/callback?code=c&state=\(state)")!
        _ = try await URLSession.shared.data(from: url, delegate: NoRedirect())
        first.stop()
        try await Task.sleep(for: .milliseconds(100))

        // 두 번째 계정 추가처럼 곧바로 다시 시도 — 앞 연결의 TIME_WAIT 때문에 실패하면 안 된다.
        let second = LoopbackCallbackServer(expectedState: state, port: port,
                                            callbackPath: CodexOAuth.callbackPath) { _ in }
        defer { second.stop() }
        #expect(try await second.start() == port)
    }

    @Test func 임의_포트_리스너는_포트_점유_오류로_바꾸지_않는다() {
        #expect(LoopbackCallbackServer.isAddressInUse(POSIXError(.EADDRINUSE)))
        #expect(!LoopbackCallbackServer.isAddressInUse(POSIXError(.EACCES)))
        #expect(!LoopbackCallbackServer.isAddressInUse(URLError(.cancelled)))
    }

    // MARK: 코디네이터 — 1455 점유

    @Test func 코디네이터는_1455가_점유돼_있으면_loopback_port_in_use로_끝낸다() async throws {
        // 1455를 먼저 쥔다. 이미 다른 앱이 쥐고 있어도 결과는 같다(코디네이터가 포트 점유로 끝난다).
        let holder = LoopbackCallbackServer(expectedState: "holder", port: 1455,
                                            callbackPath: CodexOAuth.callbackPath) { _ in }
        _ = try? await holder.start()
        defer { holder.stop() }

        var errors: [(String, String)] = []
        var codes = 0
        let coordinator = OAuthBrowserLoginCoordinator(
            provider: .codex, pkce: PKCE(),
            onCode: { _, _, _ in codes += 1 },
            onError: { message, code in errors.append((message, code)) })
        await coordinator.start(ephemeral: false)

        #expect(codes == 0)
        #expect(errors.count == 1)
        #expect(errors.first?.1 == "loopback_port_in_use")
        #expect(errors.first?.0 == L10n(lang: currentLang()).browserPortInUse)
        #expect(!coordinator.isPresenting)   // 인증 시트를 띄우지 않는다
    }

    @Test func 포트_점유_코드는_분류표_규칙에_맞고_두_언어_안내가_있다() {
        let code = LoginFailureCode.loopbackPortInUse
        #expect(code == "loopback_port_in_use")
        #expect(LoginFailureCode.sanitized(code) == code)
        #expect(L10n(lang: .ko).browserPortInUse != L10n(lang: .en).browserPortInUse)
        #expect(L10n(lang: .ko).browserPortInUse != L10n(lang: .ko).browserSessionFailed(manualFallback: false))
    }
}

/// 302를 따라가지 않는 델리게이트(completion 버전 — async 버전은 Swift 6.3 SILGen 크래시).
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
