//
//  LoginWebView.swift
//  TokenWatch
//
//  로그인 페이지를 WKWebView로 띄운다. 세 가지 캡처 방식을 지원한다:
//   - oauthCode: OAuth 콜백 리다이렉트를 가로채 authorization code 캡처(Claude/Codex).
//   - sessionCapture(cookie): 로그인 후 세션 쿠키를 관찰해 캡처(Cursor/Grok).
//   - sessionCapture(localStorage): 로그인 후 localStorage 토큰을 폴링해 캡처(Windsurf).
//  콜백이 커스텀 스킴이 아니라 https 페이지라 ASWebAuthenticationSession 대신 WKWebView를 쓴다.
//

import SwiftUI
@preconcurrency import WebKit

struct LoginWebView: UIViewRepresentable {
    let provider: AgentProvider
    let startURL: URL
    /// oauthCode 모드: 콜백에서 (code, state)를 뽑으면 호출.
    var onCode: ((String, String) -> Void)? = nil
    /// sessionCapture(cookie) 모드: 쿠키가 바뀔 때마다 호출돼 자격증명을 만들면 반환.
    var sessionProbe: (([HTTPCookie]) -> OAuthTokens?)? = nil
    /// sessionCapture(localStorage) 모드: localStorage 전체를 주기적으로 읽어 자격증명을 만들면 반환.
    var localStorageProbe: (([String: String]) -> OAuthTokens?)? = nil
    /// 세션 자격증명이 만들어지면 호출(cookie·localStorage 공통).
    var onSession: ((OAuthTokens) -> Void)? = nil
    /// 로드 실패 시.
    var onError: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(provider: provider, onCode: onCode, sessionProbe: sessionProbe,
                    localStorageProbe: localStorageProbe, onSession: onSession, onError: onError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        if sessionProbe != nil {
            webView.configuration.websiteDataStore.httpCookieStore.add(context.coordinator)
        }
        if localStorageProbe != nil {
            context.coordinator.startLocalStoragePolling(webView)
        }
        webView.load(URLRequest(url: startURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        webView.configuration.websiteDataStore.httpCookieStore.remove(coordinator)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        let provider: AgentProvider
        let onCode: ((String, String) -> Void)?
        let sessionProbe: (([HTTPCookie]) -> OAuthTokens?)?
        let localStorageProbe: (([String: String]) -> OAuthTokens?)?
        let onSession: ((OAuthTokens) -> Void)?
        let onError: ((String) -> Void)?
        private var finished = false
        private weak var webView: WKWebView?
        private var pollTimer: Timer?

        init(provider: AgentProvider,
             onCode: ((String, String) -> Void)?,
             sessionProbe: (([HTTPCookie]) -> OAuthTokens?)?,
             localStorageProbe: (([String: String]) -> OAuthTokens?)?,
             onSession: ((OAuthTokens) -> Void)?,
             onError: ((String) -> Void)?) {
            self.provider = provider
            self.onCode = onCode
            self.sessionProbe = sessionProbe
            self.localStorageProbe = localStorageProbe
            self.onSession = onSession
            self.onError = onError
        }

        func stop() { pollTimer?.invalidate(); pollTimer = nil }

        // MARK: oauthCode — 콜백 리다이렉트 가로채기

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if onCode != nil, let url = navigationAction.request.url,
               let parsed = ProviderAuth.parseCallback(provider, url) {
                decisionHandler(.cancel)
                guard !finished else { return }
                finished = true
                onCode?(parsed.code, parsed.state)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 페이지 로드마다 localStorage를 한 번 확인(SPA 대비 타이머도 병행).
            probeLocalStorage()
        }

        // MARK: sessionCapture(cookie) — 쿠키 관찰

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            guard !finished, let probe = sessionProbe else { return }
            cookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.finished, let tokens = probe(cookies) else { return }
                self.finished = true
                self.onSession?(tokens)
            }
        }

        // MARK: sessionCapture(localStorage) — 주기적 폴링

        func startLocalStoragePolling(_ webView: WKWebView) {
            self.webView = webView
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                self?.probeLocalStorage()
            }
        }

        private func probeLocalStorage() {
            guard !finished, let probe = localStorageProbe, let webView else { return }
            let js = "JSON.stringify(Object.assign({}, window.localStorage))"
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self, !self.finished,
                      let json = result as? String,
                      let data = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data),
                      let dict = obj as? [String: Any] else { return }
                let store = dict.compactMapValues { $0 as? String }
                guard let tokens = probe(store) else { return }
                self.finished = true
                self.stop()
                self.onSession?(tokens)
            }
        }

        // MARK: 공통 에러

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard !finished else { return }
            onError?(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // 콜백을 cancel하면 여기로 오는 경우가 있으므로, 이미 끝났으면 무시.
            guard !finished else { return }
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled { return }
            onError?(error.localizedDescription)
        }
    }
}
