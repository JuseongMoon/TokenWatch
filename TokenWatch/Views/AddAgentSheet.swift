//
//  AddAgentSheet.swift
//  TokenWatch
//
//  + 버튼 시트(터미널 스타일): 제공자 선택 → 로그인 → 토큰 교환 → 추가.
//  로그인 방식은 provider의 authKind로 갈린다:
//   - oauthBrowser(Claude·Grok): 앱 안 인증 시트 + 루프백 콜백 자동 수신(Claude만 폴백: 코드 붙여넣기)
//   - oauthCode(Codex): 인앱 WKWebView에서 콜백 가로채기
//   - oauthDeviceFlow(Copilot·Cursor): 앱 안 Safari View에서 승인 + 토큰 폴링 / apiKey(그 외)
//

import SwiftUI
import UIKit

struct AddAgentSheet: View {
    @Environment(AgentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @AppStorage(appLanguageStorageKey) private var appLanguage: AppLanguage = .system
    private var loc: L10n { L10n(lang: appLanguage.resolved) }

    private enum Phase: Equatable {
        case pickProvider
        case browserLogin(AgentProvider) // oauthBrowser: 인증 시트 + 루프백/코드 입력
        case login(AgentProvider)        // oauthCode: WKWebView 콜백 code 캡처
        case apiKey(AgentProvider)       // apiKey: 사용자 키 붙여넣기
        case deviceFlow(AgentProvider)   // oauthDeviceFlow: user code 발급 + 폴링
        case exchanging
        case failed(String)
    }

    @State private var phase: Phase = .pickProvider
    @State private var pkce = PKCE()
    /// 교환이 일시적 네트워크 오류로 실패했을 때 보관하는 인가 코드. RETRY가 처음부터
    /// 다시 로그인시키는 대신 이 코드로 교환만 재시도한다(코드는 아직 유효하다).
    /// 코드 만료·state 불일치 같은 영구 실패에서는 비운다.
    @State private var pendingExchange: PendingExchange?

    private struct PendingExchange: Equatable {
        let provider: AgentProvider
        let code: String
        let state: String
        let redirect: String?
    }
    @State private var apiKeyText = ""
    /// 추가 완료 여부 — 성공 dismiss가 login_abandon으로 잘못 기록되지 않게 한다.
    @State private var completed = false
    /// 인증 시트 로그인 흐름(oauthBrowser). 시스템 인증 시트가 화면을 덮는 동안에도 살아 있어야 해서
    /// 로그인 화면(BrowserLoginView)이 아니라 이 시트가 소유한다.
    @State private var browserLogin: OAuthBrowserLoginCoordinator?

    var body: some View {
        NavigationStack {
            ZStack {
                Term.bg.ignoresSafeArea()
                content
            }
            .navigationTitle("ADD AGENT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Term.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                PlainToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("[esc]")
                            .font(.term(13, weight: .semibold))
                            .foregroundStyle(Term.dim)
                    }
                    .buttonStyle(.plain)   // iOS 26 Liquid Glass 알약 배경 제거 → 터미널 테마 유지
                }
            }
        }
        .tint(Term.green)
        .onAppear { AnalyticsService.shared.log(.screenView(.addAgent)) }
        .onDisappear {
            // 시스템 시트(인증 시트·Safari View)가 위를 덮을 때 불린 onDisappear는 이탈이 아니다.
            guard browserLogin?.isPresenting != true, !InAppSafari.isPresenting else { return }
            browserLogin?.cancel()
            logAbandonIfNeeded()
        }
    }

    /// 시트가 로그인 완료 없이 닫혔을 때 어느 단계에서 이탈했는지 기록한다.
    /// (.pickProvider는 provider 미선택이라 제외, .failed는 이미 login_fail로 기록,
    ///  .exchanging은 phase에 provider가 없어 생략 — 창이 닫히는 찰나뿐이라 드물다.)
    private func logAbandonIfNeeded() {
        guard !completed else { return }
        switch phase {
        case .browserLogin(let p): AnalyticsService.shared.log(.loginAbandon(provider: p, stage: .browserWait))
        case .login(let p):      AnalyticsService.shared.log(.loginAbandon(provider: p, stage: .authorize))
        case .apiKey(let p):     AnalyticsService.shared.log(.loginAbandon(provider: p, stage: .apiKeyEntry))
        case .deviceFlow(let p): AnalyticsService.shared.log(.loginAbandon(provider: p, stage: .devicePoll))
        case .pickProvider, .exchanging, .failed: break
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .pickProvider:
            providerList
        case .browserLogin(let provider):
            browserLoginView(provider)
        case .login(let provider):
            loginView(provider)
        case .apiKey(let provider):
            apiKeyView(provider)
        case .deviceFlow(let provider):
            deviceFlowView(provider)
        case .exchanging:
            exchangingView
        case .failed(let message):
            failureView(message)
        }
    }

    // MARK: 제공자 선택 (터미널 메뉴)

    private var providerList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 로그인·조회 방식은 각 provider 정책에 달려 있다 — 예고 없이 막힐 수 있음과 감시 중임을 먼저 알린다.
                TerminalBox(title: "NOTE", titleColor: Term.yellow,
                            borderColor: Term.dim.opacity(0.5), contentPadding: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc.addAgentPolicyNotice)
                            .font(.term(12))
                            .foregroundStyle(Term.dim)
                            .fixedSize(horizontal: false, vertical: true)
                        // 서명: "토큰워치 팀" + 주간 창 게이지의 초록 슬라임이 박스 오른쪽 아래에서 제자리 점프한다
                        // (모션 줄이기면 정지 프레임, 슬라임은 보이스오버에서 숨김).
                        HStack(alignment: .bottom, spacing: 6) {
                            Spacer(minLength: 0)
                            Text(loc.addAgentNoticeSignature)
                                .font(.term(11))
                                .foregroundStyle(Term.dim)
                            AnimatedPixelSpriteView(sprite: .slime, cell: 2)
                        }
                    }
                }

                HStack(spacing: 6) {
                    Text("$").foregroundStyle(Term.dim)
                    Text("select a service to login")
                        .foregroundStyle(Term.fg)
                    BlinkingCursor(symbol: "_", color: Term.green, size: 13)
                    Spacer(minLength: 0)
                }
                .font(.term(13))

                VStack(spacing: 10) {
                    ForEach(Array(AgentProvider.allCases.enumerated()), id: \.element.id) { i, provider in
                        Button {
                            start(provider)
                        } label: {
                            HStack(spacing: 10) {
                                Text(">").foregroundStyle(Term.green)
                                Text("[\(i + 1)]").foregroundStyle(Term.dim)
                                Text(provider.terminalTag).foregroundStyle(provider.terminalColor)
                                Text(provider.displayName.lowercased()).foregroundStyle(Term.fg)
                                Spacer()
                                Text("❯").foregroundStyle(Term.dim)
                            }
                            .font(.term(15))
                            .padding(12)
                            .overlay(Rectangle().stroke(Term.dim.opacity(0.5), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: 로그인 웹뷰

    private func loginView(_ provider: AgentProvider) -> some View {
        LoginWebView(
            provider: provider,
            startURL: ProviderAuth.authorizeURL(provider, pkce: pkce),
            onCode: { code, state in
                phase = .exchanging
                Task { await exchange(provider: provider, code: code, state: state) }
            },
            onError: { message in
                AnalyticsService.shared.log(.loginFail(provider: provider, stage: .authorize, code: "webview"))
                phase = .failed(message)
            }
        )
        .background(Term.bg)
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: 로그인(앱 안 인증 시트 — oauthBrowser)

    @ViewBuilder
    private func browserLoginView(_ provider: AgentProvider) -> some View {
        if let browserLogin {
            BrowserLoginView(
                provider: provider,
                pkce: pkce,
                loc: loc,
                login: browserLogin,
                onManualCode: { code, state in
                    // 콘솔 코드 페이지로 발급된 코드라 교환도 그 redirect_uri로 한다.
                    phase = .exchanging
                    Task {
                        await exchange(provider: provider, code: code, state: state,
                                       redirect: ProviderAuth.manualCodeRedirect(provider))
                    }
                }
            )
        }
    }

    /// 인증 시트 로그인 흐름을 만든다 — 결과(code/오류)를 이 시트의 phase로 잇는다.
    private func makeBrowserLogin(_ provider: AgentProvider, pkce: PKCE) -> OAuthBrowserLoginCoordinator {
        OAuthBrowserLoginCoordinator(
            provider: provider,
            pkce: pkce,
            onCode: { code, state, redirect in
                phase = .exchanging
                Task { await exchange(provider: provider, code: code, state: state, redirect: redirect) }
            },
            onError: { message, code in
                AnalyticsService.shared.log(.loginFail(provider: provider, stage: .browserWait, code: code))
                phase = .failed(message)
            }
        )
    }

    // MARK: 인증 방식 분기

    /// provider의 authKind에 따라 다음 화면을 고른다.
    private func start(_ provider: AgentProvider) {
        AnalyticsService.shared.log(.loginStart(provider: provider))
        switch provider.authKind {
        case .oauthBrowser:
            let newPKCE = PKCE()
            pkce = newPKCE
            browserLogin?.cancel()
            browserLogin = makeBrowserLogin(provider, pkce: newPKCE)
            phase = .browserLogin(provider)
        case .oauthCode:
            pkce = PKCE()
            phase = .login(provider)
        case .apiKey:
            apiKeyText = ""
            phase = .apiKey(provider)
        case .oauthDeviceFlow:
            phase = .deviceFlow(provider)
        }
    }

    // MARK: API 키 입력

    private func apiKeyView(_ provider: AgentProvider) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 6) {
                    Text("$").foregroundStyle(Term.dim)
                    Text("paste your \(provider.displayName.lowercased()) api key")
                        .foregroundStyle(Term.fg)
                    BlinkingCursor(symbol: "_", color: Term.green, size: 13)
                    Spacer(minLength: 0)
                }
                .font(.term(13))

                // SecureField: 키를 마스킹해 앱 스위처 스냅샷(디스크 저장)에도 평문이 남지 않는다.
                SecureField("", text: $apiKeyText,
                            prompt: Text("api key…").foregroundColor(Term.dim))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.term(14))
                    .foregroundStyle(Term.fg)
                    .tint(Term.green)
                    .padding(12)
                    .overlay(Rectangle().stroke(Term.dim.opacity(0.5), lineWidth: 1))

                if let hint = loc.apiKeyHint(provider: provider) {
                    Text(hint)
                        .font(.term(12)).foregroundStyle(Term.dim)
                }

                if let url = provider.apiKeyURL {
                    // 앱 안 Safari View로 연다(키 발급 페이지는 로그인을 요구한다 — 외부 브라우저 금지).
                    Button {
                        InAppSafari.open(url)
                    } label: {
                        HStack(spacing: 6) {
                            Text(">").foregroundStyle(Term.cyan)
                            Text("[ get api key ↗ ]").foregroundStyle(Term.cyan)
                            Spacer(minLength: 0)
                        }
                        .font(.term(13))
                    }
                    .buttonStyle(.plain)
                }

                TerminalButton(title: "[ ADD ]", color: Term.green) {
                    let key = apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else { return }
                    phase = .exchanging
                    Task { await addWithAPIKey(provider: provider, key: key) }
                }
                .disabled(apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    private func addWithAPIKey(provider: AgentProvider, key: String) async {
        do {
            let tokens = try await ProviderAuth.credential(provider, apiKey: key)
            await addOrFail(provider: provider, tokens: tokens)
        } catch {
            // code에는 원문 메시지 대신 에러 타입명만 — 키·URL 혼입 방지.
            AnalyticsService.shared.log(.loginFail(provider: provider, stage: .apiKeyEntry,
                                                   code: String(describing: type(of: error))))
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: 디바이스 플로우 (GitHub Copilot 등)

    private func deviceFlowView(_ provider: AgentProvider) -> some View {
        DeviceFlowView(
            provider: provider,
            loc: loc,
            onComplete: { tokens in
                phase = .exchanging
                Task { await addOrFail(provider: provider, tokens: tokens) }
            },
            onError: { message in
                AnalyticsService.shared.log(.loginFail(provider: provider, stage: .devicePoll, code: "device_flow"))
                phase = .failed(message)
            }
        )
    }

    // MARK: 교환 중

    private var exchangingView: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                TerminalSpinner()
                Text("authenticating…").foregroundStyle(Term.fg).font(.term(15))
                BlinkingCursor(symbol: "_", color: Term.green, size: 14)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 실패

    private func failureView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            TerminalBox(title: "ERROR", titleColor: Term.red,
                        borderColor: Term.red.opacity(0.7)) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("!! LOGIN FAILED")
                        .font(.term(14, weight: .bold)).foregroundStyle(Term.red)
                    Text(message)
                        .font(.term(12)).foregroundStyle(Term.fg.opacity(0.85))
                }
            }
            if let pending = pendingExchange {
                // 받아 둔 코드로 교환만 다시 시도 — 로그인·승인을 반복시키지 않는다.
                TerminalButton(title: "[ RETRY ]", color: Term.green) {
                    phase = .exchanging
                    Task {
                        await exchange(provider: pending.provider, code: pending.code,
                                       state: pending.state, redirect: pending.redirect)
                    }
                }
            } else {
                TerminalButton(title: "[ RETRY ]", color: Term.green) {
                    pkce = PKCE()
                    phase = .pickProvider
                }
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func exchange(provider: AgentProvider, code: String, state: String,
                          redirect: String? = nil) async {
        // CSRF 방어: 콜백의 state는 로그인 시작 때 만든 값과 일치해야 한다.
        // 불일치하면 우리가 시작한 인가 흐름의 응답이 아니므로 교환하지 않는다.
        guard state == pkce.state else {
            AnalyticsService.shared.log(.loginFail(provider: provider, stage: .stateMismatch, code: "state_mismatch"))
            pendingExchange = nil
            phase = .failed(loc.errStateMismatch)
            return
        }
        do {
            let tokens = try await ProviderAuth.exchange(provider, code: code, state: state,
                                                        pkce: pkce, redirect: redirect)
            pendingExchange = nil
            await addOrFail(provider: provider, tokens: tokens)
        } catch {
            // code에는 원문 메시지 대신 에러 타입명만 — 계정 정보·URL 혼입 방지.
            AnalyticsService.shared.log(.loginFail(provider: provider, stage: .exchange,
                                                   code: String(describing: type(of: error))))
            // 네트워크가 끊겨 요청이 서버에 닿지 못한 경우엔 코드가 살아 있으므로 보관한다.
            if let urlError = error as? URLError, ClaudeOAuth.isTransient(urlError) {
                pendingExchange = PendingExchange(provider: provider, code: code, state: state, redirect: redirect)
            } else {
                pendingExchange = nil
            }
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .failed(msg)
        }
    }

    /// 토큰 저장(Keychain)까지 성공하면 닫고, 실패하면 에러 화면으로 보낸다.
    private func addOrFail(provider: AgentProvider, tokens: OAuthTokens) async {
        if await store.addAgent(provider: provider, tokens: tokens) {
            completed = true   // 성공 dismiss — onDisappear의 abandon 기록을 막는다
            dismiss()
        } else {
            AnalyticsService.shared.log(.loginFail(provider: provider, stage: .keychain, code: "keychain_save"))
            pendingExchange = nil
            phase = .failed(loc.errKeychainSave)
        }
    }
}

// MARK: - 로그인 화면 (앱 안 인증 시트)

/// 앱 안의 인증 시트로 로그인하고 code를 받아오는 화면(oauthBrowser).
///
/// 흐름 자체(루프백 리스너 + ASWebAuthenticationSession)는 `OAuthBrowserLoginCoordinator`가 맡고,
/// 이 뷰는 버튼과 상태 표시만 한다. 결과는 두 경로 중 하나로 들어온다:
///  1. 자동 — 승인하면 시트가 닫히고 코디네이터가 code를 넘긴다.
///  2. 코드 붙여넣기 — 콘솔 코드 페이지(앱 안 Safari View)에서 사용자가 복사해 온다(1이 안 될 때의 폴백).
///     이 폴백은 `ProviderAuth.manualCodeRedirect`가 있는 provider에만 보인다.
private struct BrowserLoginView: View {
    let provider: AgentProvider
    let pkce: PKCE
    let loc: L10n
    let login: OAuthBrowserLoginCoordinator
    /// 수동 입력으로 받은 (code, state). 콘솔 콜백으로 발급된 코드다.
    let onManualCode: (String, String) -> Void

    private enum Stage { case intro, manual }

    @State private var stage: Stage = .intro
    @State private var codeText = ""
    @State private var inlineError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 6) {
                    Text("$").foregroundStyle(Term.dim)
                    Text("login to \(provider.displayName.lowercased())")
                        .foregroundStyle(Term.fg)
                    BlinkingCursor(symbol: "_", color: Term.green, size: 13)
                    Spacer(minLength: 0)
                }
                .font(.term(13))

                switch stage {
                case .intro: introSection
                case .manual: manualSection
                }

                if let inlineError {
                    Text(inlineError)
                        .font(.term(12))
                        .foregroundStyle(Term.red)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    // MARK: 로그인

    @ViewBuilder private var introSection: some View {
        Text(loc.browserSheetIntro(provider: provider.displayName))
            .font(.term(13)).foregroundStyle(Term.fg)

        if login.isPresenting {
            HStack(spacing: 8) {
                TerminalSpinner(size: 12)
                Text(loc.browserWaiting).font(.term(13)).foregroundStyle(Term.fg)
                Spacer(minLength: 0)
            }
        } else {
            TerminalButton(title: loc.browserSheetOpen, color: Term.green) {
                Task { await login.start(ephemeral: false) }
            }
            if login.wasCancelled {
                Text(loc.browserCancelledHint)
                    .font(.term(12)).foregroundStyle(Term.dim)
            }

            Text(loc.browserOtherAccountHint)
                .font(.term(12)).foregroundStyle(Term.dim)
                .padding(.top, 6)
            // Safari에 로그인된 계정을 쓰지 않는 세션 — 두 번째 계정을 추가할 때.
            TerminalButton(title: loc.browserOtherAccount, color: Term.cyan, dashedBorder: true) {
                Task { await login.start(ephemeral: true) }
            }
        }

        if ProviderAuth.manualCodeRedirect(provider) != nil {
            manualEntryLink
        }
    }

    @ViewBuilder private var manualEntryLink: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.browserManualHint)
                .font(.term(12)).foregroundStyle(Term.dim)
            TerminalButton(title: loc.browserManualButton, color: Term.dim, dashedBorder: true) {
                inlineError = nil
                stage = .manual
            }
        }
        .padding(.top, 8)
    }

    // MARK: 수동(코드 붙여넣기) 모드

    @ViewBuilder private var manualSection: some View {
        Text(loc.manualCodePrompt)
            .font(.term(13)).foregroundStyle(Term.fg)

        TerminalButton(title: loc.manualCodeGet, color: Term.cyan) {
            // 콘솔 코드 페이지로 끝나는 인가 URL(같은 PKCE). 앱 안 Safari View로 연다.
            if let redirect = ProviderAuth.manualCodeRedirect(provider) {
                InAppSafari.open(ProviderAuth.authorizeURL(provider, pkce: pkce, redirect: redirect))
            }
        }

        HStack(spacing: 10) {
            TextField("", text: $codeText,
                      prompt: Text(loc.manualCodePlaceholder).foregroundColor(Term.dim))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .font(.term(14))
                .foregroundStyle(Term.fg)
                .tint(Term.green)
                .padding(12)
                .overlay(Rectangle().stroke(Term.dim.opacity(0.5), lineWidth: 1))

            // 시스템 붙여넣기 버튼 — 클립보드 접근 알림이 뜨지 않는다.
            PasteButton(payloadType: String.self) { strings in
                guard let first = strings.first else { return }
                codeText = first
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.roundedRectangle)
            .tint(Term.green)
        }

        TerminalButton(title: loc.manualConnect, color: Term.green) { submitManual() }
    }

    private func submitManual() {
        inlineError = nil
        guard let parsed = ClaudeOAuth.parseManualCode(codeText, fallbackState: pkce.state) else {
            AnalyticsService.shared.log(.loginFail(provider: provider, stage: .codeEntry, code: "code_parse"))
            inlineError = loc.errCodeInvalid
            return
        }
        onManualCode(parsed.code, parsed.state)
    }
}

// MARK: - 폴링 로그인 화면 (device flow류)

/// 폴링 로그인: 승인 페이지를 앱 안 Safari View로 열고 → 승인될 때까지 토큰을 폴링한다.
/// Copilot은 발급받은 코드를 페이지에 입력하고, 코드가 없는 흐름은 페이지를 곧바로 열어 승인만 받는다.
/// provider별 차이는 `ProviderAuth.startPollingLogin`이 정한다.
private struct DeviceFlowView: View {
    let provider: AgentProvider
    let loc: L10n
    let onComplete: (OAuthTokens) -> Void
    let onError: (String) -> Void

    /// 로그인이 시작돼 승인 페이지 정보를 받았다.
    @State private var started = false
    @State private var userCode: String?
    @State private var verificationURI: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 6) {
                    Text("$").foregroundStyle(Term.dim)
                    Text("login to \(provider.displayName.lowercased())")
                        .foregroundStyle(Term.fg)
                    BlinkingCursor(symbol: "_", color: Term.green, size: 13)
                    Spacer(minLength: 0)
                }
                .font(.term(13))

                if started {
                    if let code = userCode {
                        Text(loc.deviceFlowPrompt)
                            .font(.term(13)).foregroundStyle(Term.dim)

                        Text(code)
                            .font(.term(28, weight: .bold))
                            .foregroundStyle(Term.green)
                            .tracking(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .overlay(Rectangle().stroke(Term.dim.opacity(0.6), lineWidth: 1))
                    } else {
                        Text(loc.pollingLoginPrompt(provider: provider.displayName))
                            .font(.term(13)).foregroundStyle(Term.dim)
                    }

                    if let uri = verificationURI {
                        // 앱 안 Safari View로 연다. 코드 입력칸이 시트에 가려지니 코드가 있으면 복사해 둔다.
                        Button {
                            if let userCode { UIPasteboard.general.string = userCode }
                            InAppSafari.open(uri)
                        } label: {
                            Text(userCode == nil ? loc.pollingLoginOpen : loc.deviceFlowOpen)
                                .font(.term(14, weight: .semibold))
                                .foregroundStyle(Term.cyan)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .overlay(Rectangle().stroke(Term.cyan.opacity(0.6), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 8) {
                        TerminalSpinner(size: 12)
                        Text(loc.deviceFlowWaiting).font(.term(12)).foregroundStyle(Term.dim)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 4)
                } else {
                    HStack(spacing: 8) {
                        TerminalSpinner()
                        Text(loc.deviceFlowRequesting).font(.term(14)).foregroundStyle(Term.fg)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .task { await run() }
    }

    private func run() async {
        do {
            let login = try await ProviderAuth.startPollingLogin(provider)
            userCode = login.userCode
            verificationURI = login.verificationURL
            started = true
            // 입력할 코드가 없는 흐름은 승인 페이지를 바로 연다(코드가 있으면 코드를 본 뒤 사용자가 연다).
            if login.userCode == nil, let url = login.verificationURL {
                InAppSafari.open(url)
            }
            let tokens = try await login.poll()
            // 승인 페이지가 아직 떠 있으면 닫는다(Safari View는 스스로 닫히지 않는다).
            InAppSafari.close()
            onComplete(tokens)
        } catch is CancellationError {
            // 화면 이탈로 취소됨 — 무시.
        } catch let error as URLError where error.code == .cancelled {
            // 화면 이탈로 진행 중이던 요청이 끊김 — 취소와 같다(로그인 실패로 기록하지 않는다).
        } catch {
            InAppSafari.close()
            onError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

#Preview {
    AddAgentSheet().environment(AgentStore())
}
