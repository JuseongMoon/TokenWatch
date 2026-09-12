//
//  LoginWebView.swift
//  TokenWatch
//
//  로그인 페이지를 WKWebView로 띄우고, OAuth 콜백 리다이렉트를 가로채
//  authorization code를 캡처한다(현재는 Codex 전용).
//  콜백이 커스텀 스킴이 아니라 http(s) 주소라 ASWebAuthenticationSession 대신 WKWebView를 쓴다.
//
//  ⚠️ 한계: WKUIDelegate가 없어 `window.open` 팝업이 열리지 않는다. 팝업으로 동작하는
//     소셜 로그인(구글 "Continue with Google" 등)은 이 경로에서 실패한다. Claude는 그래서
//     외부 브라우저 방식(BrowserLoginView + LoopbackCallbackServer)으로 옮겼다.
//

import SwiftUI
@preconcurrency import WebKit

struct LoginWebView: UIViewRepresentable {
    let provider: AgentProvider
    let startURL: URL
    /// 콜백에서 (code, state)를 뽑으면 호출.
    var onCode: ((String, String) -> Void)? = nil
    /// 로드 실패 시.
    var onError: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(provider: provider, onCode: onCode, onError: onError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 로그인 1회용 웹뷰 — 세션 쿠키·스토리지가 앱 컨테이너 디스크에 남지 않도록
        // 비영속 스토어를 쓴다(로그아웃 후 재추가 시 자동 재로그인되는 문제도 함께 차단).
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: startURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let provider: AgentProvider
        let onCode: ((String, String) -> Void)?
        let onError: ((String) -> Void)?
        private var finished = false

        init(provider: AgentProvider,
             onCode: ((String, String) -> Void)?,
             onError: ((String) -> Void)?) {
            self.provider = provider
            self.onCode = onCode
            self.onError = onError
        }

        // MARK: 콜백 리다이렉트 가로채기

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

        // MARK: 에러

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
