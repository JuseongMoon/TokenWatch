//
//  LoopbackOutcomeTests.swift
//  TokenWatchTests
//
//  A5: 인증 시트 로그인의 종료 결과 — 오류 콜백(state 검증 포함)과 리스너 시간 초과가
//  한 번만, 올바른 시도에만 전달되는지. 리스너 수명은 짧게 주입해 실제 10분을 기다리지 않는다.
//  기존 302 전송 순서 검증(OAuthBrowserLoginTests)은 그대로 둔다.
//

import Testing
import Foundation
@testable import TokenWatch

@MainActor
struct LoopbackOutcomeTests {
    private let state = "expected-state"

    // MARK: 콜백 해석

    @Test func 올바른_state의_오류_콜백은_오류로_해석한다() {
        #expect(LoopbackCallbackServer.parseCallbackResult(
            target: "/callback?error=access_denied&error_description=User%20denied&state=\(state)",
            expectedState: state) == .oauthError("access_denied", state: state))
        // 정상 콜백은 기존과 같다.
        #expect(LoopbackCallbackServer.parseCallbackResult(
            target: "/callback?code=abc&state=\(state)", expectedState: state) == .code("abc", state: state))
    }

    @Test func state나_경로가_다른_오류_콜백은_현재_시도를_끝내지_않는다() {
        #expect(LoopbackCallbackServer.parseCallbackResult(
            target: "/callback?error=access_denied&state=attacker", expectedState: state) == nil)
        #expect(LoopbackCallbackServer.parseCallbackResult(
            target: "/other?error=access_denied&state=\(state)", expectedState: state) == nil)
        // 형식에 맞지 않는 error 값(공백·URL 등)은 받지 않는다.
        #expect(LoopbackCallbackServer.parseCallbackResult(
            target: "/callback?error=https%3A%2F%2Fevil&state=\(state)", expectedState: state) == nil)
        #expect(LoopbackCallbackServer.sanitizedOAuthError("access denied") == nil)
        #expect(LoopbackCallbackServer.sanitizedOAuthError("server_error") == "server_error")
    }

    @Test func state가_없는_오류_콜백은_받아들이고_code_콜백은_state를_계속_요구한다() {
        // 인가 서버가 오류 리다이렉트에 state를 싣지 않는 경우.
        #expect(LoopbackCallbackServer.parseCallbackResult(
            target: "/callback?error=access_denied", expectedState: state) == .oauthError("access_denied", state: state))
        #expect(LoopbackCallbackServer.parseCallbackResult(
            target: "/callback?error=access_denied&state=", expectedState: state) == nil)   // 빈 state도 불일치
        // code 콜백은 state가 없거나 다르면 받지 않는다.
        #expect(LoopbackCallbackServer.parseCallbackResult(
            target: "/callback?code=abc", expectedState: state) == nil)
        #expect(LoopbackCallbackServer.parseCallbackResult(
            target: "/callback?code=abc&state=attacker", expectedState: state) == nil)
        // code와 error가 함께 오고 state가 다르면 오류로도 받지 않는다(code 규칙이 우선).
        #expect(LoopbackCallbackServer.parseCallbackResult(
            target: "/callback?code=abc&error=x&state=attacker", expectedState: state) == nil)
        // state 없는 오류 콜백의 시트 리다이렉트는 우리 state를 실어 시트 쪽 검증을 통과한다.
        let location = LoopbackCallbackServer.redirectLocation(error: "access_denied", state: state)
        #expect(URL(string: location).flatMap {
            LoopbackCallbackServer.parseSessionError($0, expectedState: state)
        } == "access_denied")
    }

    @Test func 리스너가_state_없는_거절_콜백도_302로_돌려보내고_한_번_전달한다() async throws {
        var outcomes: [LoopbackOutcome] = []
        let server = LoopbackCallbackServer(expectedState: state) { outcomes.append($0) }
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/callback?error=access_denied")!
        let (_, response) = try await URLSession.shared.data(from: url, delegate: NoFollowDelegate())
        #expect((response as? HTTPURLResponse)?.statusCode == 302)
        await eventually { !outcomes.isEmpty }
        #expect(outcomes == [.oauthError("access_denied")])
    }

    @Test func 오류_리다이렉트_주소는_시트_콜백으로_돌아와_state를_검증한다() {
        let location = LoopbackCallbackServer.redirectLocation(error: "access_denied", state: state)
        let url = URL(string: location)!
        #expect(LoopbackCallbackServer.parseSessionError(url, expectedState: state) == "access_denied")
        #expect(LoopbackCallbackServer.parseSessionError(url, expectedState: "other") == nil)
        // 오류 콜백은 code 콜백으로 읽히지 않는다.
        #expect(LoopbackCallbackServer.parseSessionCallback(url) == nil)
    }

    @Test func 분석_코드는_기존_분류표_값만_쓴다() {
        #expect(OAuthBrowserLoginCoordinator.analyticsCode(forOAuthError: "access_denied") == "denied")
        #expect(OAuthBrowserLoginCoordinator.analyticsCode(forOAuthError: "invalid_client") == "invalid_client")
        #expect(OAuthBrowserLoginCoordinator.analyticsCode(forOAuthError: "server_error") == "other")
    }

    @Test func 거절과_시간_초과_안내가_두_언어로_있다() {
        for lang in [Lang.ko, Lang.en] {
            let loc = L10n(lang: lang)
            #expect(!loc.browserLoginDenied.isEmpty)
            #expect(!loc.browserLoginTimedOut.isEmpty)
            #expect(loc.browserLoginDenied != loc.browserLoginProviderError)
            #expect(loc.browserLoginTimedOut != loc.browserCancelledHint)
        }
        #expect(L10n(lang: .ko).browserLoginTimedOut != L10n(lang: .en).browserLoginTimedOut)
    }

    // MARK: 시도 래치 (one-shot)

    @Test func 한_시도의_결과는_처음_하나만_전달된다() {
        var latch = LoginAttemptLatch()
        let a = latch.begin()!
        let concurrent = latch.begin()
        #expect(concurrent == nil)           // 진행 중에는 새 시도를 시작하지 않는다
        let success = latch.finish(a)
        let lateTimeout = latch.finish(a)
        #expect(success)                     // 성공
        #expect(!lateTimeout)                // 직후 시간 초과·취소는 무시
    }

    @Test func 이전_시도의_늦은_이벤트는_새_시도를_끝내지_못한다() {
        var latch = LoginAttemptLatch()
        let first = latch.begin()!
        let denied = latch.finish(first)     // 거절로 끝남
        let second = latch.begin()!          // 재시도
        let lateFromFirst = latch.finish(first)
        let liveAfterLate = latch.isLive(second)
        let retrySuccess = latch.finish(second)
        #expect(denied)
        #expect(!lateFromFirst)              // 첫 시도의 늦은 시간 초과
        #expect(liveAfterLate)
        #expect(retrySuccess)                // 재시도 성공
    }

    @Test func 화면이_닫히면_진행_중_시도의_이벤트를_모두_버린다() {
        var latch = LoginAttemptLatch()
        let a = latch.begin()!
        latch.invalidate()                   // 사용자 취소·시트 닫힘
        let late = latch.finish(a)
        let retry = latch.begin()
        #expect(!late)
        #expect(retry != nil)                // 다시 시도할 수 있다
    }

    // MARK: 리스너 통합(실제 소켓)

    @Test func 리스너가_올바른_state의_거절_콜백을_302로_돌려보내고_한_번_전달한다() async throws {
        var outcomes: [LoopbackOutcome] = []
        let server = LoopbackCallbackServer(expectedState: state) { outcomes.append($0) }
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/callback?error=access_denied&state=\(state)")!
        let (_, response) = try await URLSession.shared.data(from: url, delegate: NoFollowDelegate())
        let http = response as? HTTPURLResponse
        #expect(http?.statusCode == 302)
        let location = http?.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:))
        #expect(location.flatMap { LoopbackCallbackServer.parseSessionError($0, expectedState: state) } == "access_denied")

        await eventually { !outcomes.isEmpty }
        try await Task.sleep(for: .milliseconds(1200))   // 전송 완료·1초 안전망이 모두 돈 뒤에도
        #expect(outcomes == [.oauthError("access_denied")])
    }

    @Test func 리스너가_다른_state의_거절_콜백은_404로_막고_전달하지_않는다() async throws {
        var outcomes: [LoopbackOutcome] = []
        let server = LoopbackCallbackServer(expectedState: state) { outcomes.append($0) }
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/callback?error=access_denied&state=wrong")!
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
        #expect(outcomes.isEmpty)
    }

    @Test func 콜백이_없으면_수명이_끝날_때_시간_초과를_한_번_전달한다() async throws {
        var outcomes: [LoopbackOutcome] = []
        let server = LoopbackCallbackServer(expectedState: state, lifetime: .milliseconds(200)) {
            outcomes.append($0)
        }
        _ = try await server.start()
        defer { server.stop() }

        await eventually { !outcomes.isEmpty }
        try await Task.sleep(for: .milliseconds(300))
        #expect(outcomes == [.timedOut])
    }

    @Test func 성공_직후_수명이_끝나도_시간_초과를_전달하지_않는다() async throws {
        var outcomes: [LoopbackOutcome] = []
        let server = LoopbackCallbackServer(expectedState: state, lifetime: .milliseconds(400)) {
            outcomes.append($0)
        }
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/callback?code=c&state=\(state)")!
        _ = try await URLSession.shared.data(from: url, delegate: NoFollowDelegate())
        try await Task.sleep(for: .milliseconds(1300))
        #expect(outcomes == [.code("c", state: state)])
    }

    @Test func 멈춘_리스너는_시간_초과를_전달하지_않는다() async throws {
        var outcomes: [LoopbackOutcome] = []
        let server = LoopbackCallbackServer(expectedState: state, lifetime: .milliseconds(200)) {
            outcomes.append($0)
        }
        _ = try await server.start()
        server.stop()   // 사용자 취소·화면 닫힘
        try await Task.sleep(for: .milliseconds(400))
        #expect(outcomes.isEmpty)
    }
}

/// 302를 따라가지 않는 델리게이트(completion 버전 — async 버전은 Swift 6.3 SILGen 크래시).
private final class NoFollowDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
