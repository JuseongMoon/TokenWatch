//
//  InAppSafari.swift
//  TokenWatch
//
//  앱 안에서 웹 페이지를 여는 SFSafariViewController 프레젠터.
//
//  로그인·인증과 관련된 페이지(Copilot 승인, API 키 발급, Claude 수동 코드)를 외부 Safari로
//  보내면 App Store 가이드라인 4("taken to the default web browser to sign in")에 걸린다.
//  그래서 시스템 Safari View로 앱 위에 띄운다. 자동 콜백이 필요한 인증 시트 로그인은
//  `OAuthBrowserLoginCoordinator`(ASWebAuthenticationSession)가 따로 맡는다.
//
//  시트(pageSheet)로 띄운다: 전체 화면으로 덮으면 아래 SwiftUI 화면의 onDisappear가 불려
//  폴링 task가 취소되거나 이탈 분석이 잘못 기록될 수 있다.
//

import SafariServices
import SwiftUI
import UIKit

enum InAppSafari {
    /// 지금 떠 있는 Safari View. 닫히면 UIKit이 놓아 자동으로 nil이 된다.
    private static weak var current: SFSafariViewController?

    static var isPresenting: Bool { current != nil }

    static func open(_ url: URL) {
        guard current == nil, let top = UIApplication.shared.topViewControllerForPresentation else { return }
        let safari = SFSafariViewController(url: url)
        safari.preferredBarTintColor = .black
        safari.preferredControlTintColor = UIColor(Term.green)
        safari.dismissButtonStyle = .close
        safari.modalPresentationStyle = .pageSheet
        current = safari
        top.present(safari, animated: true)
    }

    /// 떠 있으면 닫는다(예: Copilot 승인이 끝나 폴링이 성공했을 때).
    static func close() {
        current?.dismiss(animated: true)
    }
}

extension UIApplication {
    /// 전면 씬의 키 윈도우 — 시스템 시트(인증 세션·Safari View)를 띄울 기준 창.
    var foregroundKeyWindow: UIWindow? {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return active?.keyWindow ?? active?.windows.first
    }

    /// 지금 가장 위에 떠 있는 뷰 컨트롤러(열린 시트 포함).
    var topViewControllerForPresentation: UIViewController? {
        var top = foregroundKeyWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
