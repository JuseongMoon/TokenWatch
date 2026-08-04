//
//  LoginWebView.swift
//  TokenWatch
//
//  로그인 페이지를 WKWebView로 띄우고, OAuth 콜백 리다이렉트를 가로채
//  authorization code를 캡처한다(Claude/Codex).
//  콜백이 커스텀 스킴이 아니라 https 페이지라 ASWebAuthenticationSession 대신 WKWebView를 쓴다.
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
