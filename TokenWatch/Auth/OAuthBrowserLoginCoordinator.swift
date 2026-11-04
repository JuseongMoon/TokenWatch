//
//  OAuthBrowserLoginCoordinator.swift
//  TokenWatch
//
//  인증 시트 로그인(`AuthKind.oauthBrowser`) 한 번(인증 시트 표시 → code 수신)을 끝까지 책임지는 객체.
//  provider마다 다른 부분(루프백 redirect_uri 형식·authorize URL)은 `ProviderAuth`가 정한다.
//
//  구조: 앱이 루프백 리스너(`LoopbackCallbackServer`)를 띄우고, 앱 위에 뜨는 시스템 인증
//  시트(ASWebAuthenticationSession — Safari 엔진)에서 authorize를 연다. 승인되면 인가 서버가
//  루프백 주소(예: `http://localhost:PORT/callback`)로 보내고, 리스너가 302로 `tokenwatch://login-complete`에
//  보내면 시트가 스스로 닫힌다. 리스너 전달과 시트 콜백 중 먼저 온 것 하나만 쓴다.
//
//  왜 외부 Safari가 아닌가: 앱 밖 기본 브라우저로 로그인시키면 App Store 가이드라인 4로 거절된다.
//  왜 WKWebView가 아닌가: claude.ai의 Google 로그인은 `window.open` 팝업이라 WKWebView에서는
//  "로그인 중 오류"만 뜬다. 인증 시트 안에서는 팝업이 정상 동작한다(실기기 확인 2026-09-14).
//  Apple 로그인은 팝업이 아니라 페이지 리다이렉트다.
//
//  왜 뷰 밖에 두는가: 시스템 시트가 화면을 덮거나 phase 전환으로 로그인 화면이 사라질 때
//  SwiftUI의 onDisappear가 불릴 수 있다. 수명을 뷰에 묶으면 로그인 도중 리스너가 죽는다.
//  그래서 이 객체는 `AddAgentSheet`가 들고, 명시적 이벤트(결과·취소·시트 닫힘)로만 정리한다.
//
//  주의(보고된 거동): `ASWebAuthenticationSession.cancel()`은 완료 핸들러를 부르지 않는다.
//  세션은 스스로를 붙잡지 않고 `presentationContextProvider`는 weak라, 둘 다 여기서 강하게 보유한다.
//

import AuthenticationServices
import Observation
import UIKit

@MainActor
@Observable
final class OAuthBrowserLoginCoordinator {
    /// 시스템 인증 시트가 떠 있는 동안 true. 이 동안의 onDisappear는 이탈이 아니다.
    private(set) var isPresenting = false
    /// 사용자가 시트를 닫아 마지막 시도가 끝났다(오류 아님) — 안내 문구용.
    private(set) var wasCancelled = false

    private let provider: AgentProvider
    private let pkce: PKCE
    private let onCode: (_ code: String, _ state: String, _ redirect: String) -> Void
    private let onError: (_ message: String, _ analyticsCode: String) -> Void
    private let anchor = PresentationAnchorProvider()

    @ObservationIgnored private var server: LoopbackCallbackServer?
    /// 마지막 세션. 끝난 뒤에도 다음 시도나 이 객체가 사라질 때까지 붙잡는다(해제 타이밍 크래시 회피).
    @ObservationIgnored private var session: ASWebAuthenticationSession?
    @ObservationIgnored private var redirect: String?
    /// 시도당 결과는 한 번만 전달하고(리스너·시트 콜백·시간 초과가 겹칠 수 있다),
    /// 늦게 도착한 이전 시도의 이벤트는 버린다.
    @ObservationIgnored private var latch = LoginAttemptLatch()
    /// 루프백 리스너 수명(로그인 대기 시간 상한). 테스트·디버그용으로만 바꾼다.
    @ObservationIgnored private let listenerLifetime: Duration

    init(provider: AgentProvider,
         pkce: PKCE,
         onCode: @escaping (_ code: String, _ state: String, _ redirect: String) -> Void,
         onError: @escaping (_ message: String, _ analyticsCode: String) -> Void,
         listenerLifetime: Duration = LoopbackCallbackServer.defaultLifetime) {
        self.listenerLifetime = listenerLifetime
        self.provider = provider
        self.pkce = pkce
        self.onCode = onCode
        self.onError = onError
    }

    // MARK: 시작

    /// - Parameter ephemeral: true면 Safari에 로그인된 계정을 쓰지 않는다(다른 계정으로 로그인).
    func start(ephemeral: Bool) async {
        guard !isPresenting, let current = latch.begin() else { return }
        wasCancelled = false

        let listener = LoopbackCallbackServer(expectedState: pkce.state,
                                              lifetime: listenerLifetime) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .code(let code, let state): self.receive(code: code, state: state, attempt: current)
            case .oauthError(let error): self.providerRejected(error: error, attempt: current)
            case .timedOut: self.timedOut(attempt: current)
            }
        }
        let port: UInt16
        do {
            port = try await listener.start()
        } catch {
            listener.stop()
            guard latch.isLive(current) else { return }
            fail(sessionFailedMessage, analyticsCode: "loopback_listen", attempt: current)
            return
        }
        // 리스너를 띄우는 사이 시트가 닫혔다면(cancel) 이 시도는 버린다.
        guard latch.isLive(current) else {
            listener.stop()
            return
        }
        server = listener
        guard let redirect = ProviderAuth.loopbackRedirectURI(provider, port: port) else {
            // 루프백 콜백을 쓰지 않는 provider — AddAgentSheet가 이 경로로 보내지 않는다.
            fail(sessionFailedMessage, analyticsCode: "unsupported_provider", attempt: current)
            return
        }
        self.redirect = redirect

        let url = ProviderAuth.authorizeURL(provider, pkce: pkce, redirect: redirect)
        let authSession = ASWebAuthenticationSession(
            url: url, callbackURLScheme: LoopbackCallbackServer.sessionCallbackScheme
        ) { @Sendable [weak self] callbackURL, error in
            // 에러 객체 대신 판별에 필요한 값만 넘긴다.
            let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
            let errorCode = error.map { ($0 as NSError).code }
            guard let self else { return }
            Task { @MainActor in
                self.sessionEnded(callbackURL: callbackURL, cancelled: cancelled,
                                  errorCode: errorCode, attempt: current)
            }
        }
        authSession.prefersEphemeralWebBrowserSession = ephemeral
        authSession.presentationContextProvider = anchor
        session = authSession
        isPresenting = true
        if !authSession.start() {
            isPresenting = false
            fail(sessionFailedMessage, analyticsCode: "auth_session_start", attempt: current)
        }
    }

    // MARK: 종료

    /// 로그인 화면(추가 시트)이 실제로 닫힐 때 — 진행 중인 리스너·시트를 정리하고 결과는 버린다.
    func cancel() {
        latch.invalidate()
        if isPresenting {
            session?.cancel()
            isPresenting = false
        }
        stopServer()
    }

    /// 루프백 리스너가 code를 받았다(302 전송 뒤).
    private func receive(code: String, state: String, attempt: Int) {
        guard latch.isLive(attempt), let redirect else { return }
        _ = latch.finish(attempt)
        // 리스너는 응답을 보낸 뒤 스스로 접힌다 — 여기서 멈추지 않는다.
        server = nil
        closeSheetSoon(attempt: attempt)
        onCode(code, state, redirect)
    }

    /// 보통은 방금 보낸 302로 시트가 곧 스스로 닫힌다. 잠시 뒤에도 떠 있으면 직접 닫는다.
    private func closeSheetSoon(attempt: Int) {
        guard isPresenting else { return }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard attempt == self.latch.attempt, self.isPresenting else { return }
            self.session?.cancel()
            self.isPresenting = false
        }
    }

    /// 인가 서버가 오류로 돌려보냈다(state 검증 통과 — 예: 사용자가 승인 거부). 이 시도를 끝내고 안내한다.
    private func providerRejected(error: String, attempt: Int) {
        guard latch.finish(attempt) else { return }
        server = nil   // 리스너는 302를 보낸 뒤 스스로 접힌다
        closeSheetSoon(attempt: attempt)
        let loc = L10n(lang: currentLang())
        let message = error == "access_denied" ? loc.browserLoginDenied : loc.browserLoginProviderError
        // 분석에는 분류 코드만(원문 error_description·URL 금지). 기존 서버 분류표 안의 값만 쓴다.
        onError(message, Self.analyticsCode(forOAuthError: error))
    }

    /// 로그인 대기 시간이 다 됐다 — 시트를 닫고 다시 시도할 수 있는 상태로 안내한다.
    private func timedOut(attempt: Int) {
        guard latch.finish(attempt) else { return }
        server = nil   // 리스너가 스스로 닫혔다
        if isPresenting {
            session?.cancel()   // cancel()은 완료 핸들러를 부르지 않는다
            isPresenting = false
        }
        onError(L10n(lang: currentLang()).browserLoginTimedOut, "timed_out")
    }

    /// OAuth `error` → 로그인 실패 코드(`LoginFailureCode` 표 안의 값).
    static func analyticsCode(forOAuthError error: String) -> String {
        if error == "access_denied" { return "denied" }
        return LoginFailureCode.oauthError(error) ?? LoginFailureCode.other
    }

    /// 인증 시트가 끝났다(콜백 URL 도착·사용자 취소·오류). 프로그램으로 cancel()한 경우엔 오지 않는다.
    private func sessionEnded(callbackURL: URL?, cancelled: Bool, errorCode: Int?, attempt: Int) {
        guard attempt == latch.attempt else { return }
        isPresenting = false
        // 리스너가 이미 결과를 넘겼으면 할 일이 없다.
        guard latch.isLive(attempt) else { return }

        if let callbackURL, let redirect,
           let parsed = LoopbackCallbackServer.parseSessionCallback(callbackURL) {
            _ = latch.finish(attempt)
            server = nil
            onCode(parsed.code, parsed.state, redirect)
        } else if let callbackURL,
                  let error = LoopbackCallbackServer.parseSessionError(callbackURL, expectedState: pkce.state) {
            // 리스너보다 시트 콜백이 먼저 왔다 — 리스너는 이미 응답했으니 정리만 한다.
            stopServer()
            providerRejected(error: error, attempt: attempt)
        } else if cancelled {
            _ = latch.finish(attempt)
            wasCancelled = true
            stopServer()
        } else {
            // 분석에는 에러 코드 정수만 싣는다(원문 메시지 금지).
            // 코드 규칙(`[a-z0-9_]`)에 맞게 부호를 떼고, 코드가 없으면 other로 둔다.
            fail(sessionFailedMessage, analyticsCode: errorCode.map { "auth_session_\(abs($0))" } ?? LoginFailureCode.other,
                 attempt: attempt)
        }
    }

    /// 로그인 창을 열지 못했을 때의 안내. 코드 붙여넣기 폴백이 있는 provider만 그 방법을 함께 권한다.
    private var sessionFailedMessage: String {
        L10n(lang: currentLang())
            .browserSessionFailed(manualFallback: ProviderAuth.manualCodeRedirect(provider) != nil)
    }

    private func fail(_ message: String, analyticsCode: String, attempt: Int) {
        guard latch.finish(attempt) else { return }
        stopServer()
        onError(message, analyticsCode)
    }

    private func stopServer() {
        server?.stop()
        server = nil
    }
}

/// 로그인 시도 하나의 수명(순수 상태 — 테스트 대상).
/// 시도마다 번호를 새로 주고, 그 시도의 결과(성공·거절·취소·시간 초과·실패)는 처음 하나만 받는다.
/// 번호가 다른(이전 시도의) 늦은 이벤트는 새 시도를 끝내지 못한다.
nonisolated struct LoginAttemptLatch: Equatable, Sendable {
    private(set) var attempt = 0
    private(set) var finished = true

    /// 새 시도를 시작한다. 진행 중인 시도가 있으면 nil.
    mutating func begin() -> Int? {
        guard finished else { return nil }
        finished = false
        attempt += 1
        return attempt
    }

    /// 이 시도가 아직 결과를 기다리는 중인지.
    func isLive(_ attempt: Int) -> Bool { attempt == self.attempt && !finished }

    /// 이 시도를 끝낸다. 처음 끝낸 호출만 true(그 호출만 결과를 전달한다).
    mutating func finish(_ attempt: Int) -> Bool {
        guard isLive(attempt) else { return false }
        finished = true
        return true
    }

    /// 화면이 닫히는 등 진행 중인 시도를 결과 없이 버린다 — 이후 그 시도의 이벤트는 모두 무시된다.
    mutating func invalidate() {
        attempt += 1
        finished = true
    }
}

/// 인증 시트를 띄울 창 — 전면 씬의 키 윈도우.
final class PresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.foregroundKeyWindow ?? ASPresentationAnchor()
    }
}
