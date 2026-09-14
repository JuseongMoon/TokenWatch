//
//  ClaudeLoginCoordinator.swift
//  TokenWatch
//
//  Claude 로그인 한 번(인증 시트 표시 → code 수신)을 끝까지 책임지는 객체.
//
//  구조: 앱이 루프백 리스너(`LoopbackCallbackServer`)를 띄우고, 앱 위에 뜨는 시스템 인증
//  시트(ASWebAuthenticationSession — Safari 엔진)에서 authorize를 연다. 승인되면 인가 서버가
//  `http://localhost:PORT/callback`으로 보내고, 리스너가 302로 `tokenwatch://login-complete`에
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
final class ClaudeLoginCoordinator {
    /// 시스템 인증 시트가 떠 있는 동안 true. 이 동안의 onDisappear는 이탈이 아니다.
    private(set) var isPresenting = false
    /// 사용자가 시트를 닫아 마지막 시도가 끝났다(오류 아님) — 안내 문구용.
    private(set) var wasCancelled = false

    private let pkce: PKCE
    private let onCode: (_ code: String, _ state: String, _ redirect: String) -> Void
    private let onError: (_ message: String, _ analyticsCode: String) -> Void
    private let anchor = PresentationAnchorProvider()

    @ObservationIgnored private var server: LoopbackCallbackServer?
    /// 마지막 세션. 끝난 뒤에도 다음 시도나 이 객체가 사라질 때까지 붙잡는다(해제 타이밍 크래시 회피).
    @ObservationIgnored private var session: ASWebAuthenticationSession?
    @ObservationIgnored private var redirect: String?
    /// 시도당 결과는 한 번만 전달한다(리스너와 시트 콜백이 둘 다 올 수 있다).
    @ObservationIgnored private var finished = true
    /// 시도마다 증가 — 늦게 도착한 이전 시도의 콜백을 버린다.
    @ObservationIgnored private var attempt = 0

    init(pkce: PKCE,
         onCode: @escaping (_ code: String, _ state: String, _ redirect: String) -> Void,
         onError: @escaping (_ message: String, _ analyticsCode: String) -> Void) {
        self.pkce = pkce
        self.onCode = onCode
        self.onError = onError
    }

    // MARK: 시작

    /// - Parameter ephemeral: true면 Safari에 로그인된 계정을 쓰지 않는다(다른 계정으로 로그인).
    func start(ephemeral: Bool) async {
        guard finished, !isPresenting else { return }
        finished = false
        wasCancelled = false
        attempt += 1
        let current = attempt
        let loc = L10n(lang: currentLang())

        let listener = LoopbackCallbackServer(expectedState: pkce.state) { [weak self] code, state in
            self?.receive(code: code, state: state, attempt: current)
        }
        let port: UInt16
        do {
            port = try await listener.start()
        } catch {
            listener.stop()
            guard current == attempt else { return }
            fail(loc.browserSessionFailed, analyticsCode: "loopback_listen")
            return
        }
        // 리스너를 띄우는 사이 시트가 닫혔다면(cancel) 이 시도는 버린다.
        guard current == attempt, !finished else {
            listener.stop()
            return
        }
        server = listener
        let redirect = ClaudeOAuth.loopbackRedirectURI(port: port)
        self.redirect = redirect

        let url = ProviderAuth.authorizeURL(.claude, pkce: pkce, redirect: redirect)
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
            fail(loc.browserSessionFailed, analyticsCode: "auth_session_start")
        }
    }

    // MARK: 종료

    /// 로그인 화면(추가 시트)이 실제로 닫힐 때 — 진행 중인 리스너·시트를 정리하고 결과는 버린다.
    func cancel() {
        attempt += 1
        finished = true
        if isPresenting {
            session?.cancel()
            isPresenting = false
        }
        stopServer()
    }

    /// 루프백 리스너가 code를 받았다(302 전송 뒤).
    private func receive(code: String, state: String, attempt: Int) {
        guard attempt == self.attempt, !finished, let redirect else { return }
        finished = true
        // 리스너는 응답을 보낸 뒤 스스로 접힌다 — 여기서 멈추지 않는다.
        server = nil
        // 보통은 방금 보낸 302로 시트가 곧 스스로 닫힌다. 잠시 뒤에도 떠 있으면 직접 닫는다.
        if isPresenting {
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard attempt == self.attempt, self.isPresenting else { return }
                self.session?.cancel()
                self.isPresenting = false
            }
        }
        onCode(code, state, redirect)
    }

    /// 인증 시트가 끝났다(콜백 URL 도착·사용자 취소·오류). 프로그램으로 cancel()한 경우엔 오지 않는다.
    private func sessionEnded(callbackURL: URL?, cancelled: Bool, errorCode: Int?, attempt: Int) {
        guard attempt == self.attempt else { return }
        isPresenting = false
        // 리스너가 이미 code를 넘겼으면 할 일이 없다.
        guard !finished else { return }

        if let callbackURL, let redirect,
           let parsed = LoopbackCallbackServer.parseSessionCallback(callbackURL) {
            finished = true
            server = nil
            onCode(parsed.code, parsed.state, redirect)
        } else if cancelled {
            finished = true
            wasCancelled = true
            stopServer()
        } else {
            // 분석에는 에러 코드 정수만 싣는다(원문 메시지 금지).
            fail(L10n(lang: currentLang()).browserSessionFailed,
                 analyticsCode: "auth_session_\(errorCode ?? -1)")
        }
    }

    private func fail(_ message: String, analyticsCode: String) {
        finished = true
        stopServer()
        onError(message, analyticsCode)
    }

    private func stopServer() {
        server?.stop()
        server = nil
    }
}

/// 인증 시트를 띄울 창 — 전면 씬의 키 윈도우.
final class PresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.foregroundKeyWindow ?? ASPresentationAnchor()
    }
}
