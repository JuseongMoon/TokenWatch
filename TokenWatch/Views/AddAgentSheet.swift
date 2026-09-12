//
//  AddAgentSheet.swift
//  TokenWatch
//
//  + 버튼 시트(터미널 스타일): 제공자 선택 → 로그인 → 토큰 교환 → 추가.
//  로그인 방식은 provider의 authKind로 갈린다:
//   - oauthBrowser(Claude): 외부 브라우저 + 루프백 콜백 자동 수신(폴백: 코드 붙여넣기)
//   - oauthCode(Codex): 인앱 WKWebView에서 콜백 가로채기
//   - oauthDeviceFlow(Copilot) / apiKey(그 외)
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
        case browserLogin(AgentProvider) // oauthBrowser: 외부 브라우저 + 루프백/코드 입력
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
        .onDisappear { logAbandonIfNeeded() }
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

    // MARK: 브라우저 로그인(Claude)

    private func browserLoginView(_ provider: AgentProvider) -> some View {
        BrowserLoginView(
            provider: provider,
            pkce: pkce,
            loc: loc,
            onCode: { code, state, redirect in
                phase = .exchanging
                Task { await exchange(provider: provider, code: code, state: state, redirect: redirect) }
            },
            onError: { message in
                AnalyticsService.shared.log(.loginFail(provider: provider, stage: .browserWait, code: "browser"))
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
            pkce = PKCE()
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

                if let url = provider.apiKeyURL {
                    Link(destination: url) {
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
        let tokens = ProviderAuth.credential(provider, apiKey: key)
        await addOrFail(provider: provider, tokens: tokens)
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

// MARK: - 브라우저 로그인 화면 (Claude)

/// 외부 브라우저에서 로그인하고 code를 받아오는 화면.
///
/// 인앱 웹뷰(WKWebView·SFSafariViewController 계열)는 `window.open` 팝업을 제대로
/// 띄우지 못한다. claude.ai의 구글/애플 로그인 버튼이 바로 그 팝업 방식이라
/// 인앱에서는 "로그인 중 오류" 화면만 나온다. 그래서 로그인 자체는 전체 브라우저에
/// 맡기고, 결과만 두 경로 중 하나로 받는다:
///  1. 루프백 자동 수신 — 앱이 띄운 `LoopbackCallbackServer`로 리다이렉트가 들어온다.
///  2. 코드 붙여넣기 — 콘솔 코드 페이지에서 사용자가 복사해 온다(1이 실패할 때의 폴백).
///
/// 로그인(①)과 승인(②)을 분리하는 이유: 앱이 브라우저 뒤로 가면 약 30초 뒤 정지되어
/// 루프백에 응답할 수 없다. 구글 로그인 전체를 한 흐름에서 하면 이 시간을 넘겨 Safari에
/// "서버에 연결할 수 없음"이 뜬다(코드는 복귀 시 수신되지만 사용자는 실패로 오해한다).
/// 승인만 따로 하면 몇 초라 유예 안에 끝나고 완료 페이지가 정상 표시된다.
private struct BrowserLoginView: View {
    let provider: AgentProvider
    let pkce: PKCE
    let loc: L10n
    /// (code, state, 교환에 쓸 redirect_uri)
    let onCode: (String, String, String) -> Void
    let onError: (String) -> Void

    private enum Stage { case intro, waiting, manual }

    @Environment(\.openURL) private var openURL

    @State private var stage: Stage = .intro
    @State private var server: LoopbackCallbackServer?
    @State private var loopbackRedirect: String?
    @State private var codeText = ""
    @State private var inlineError: String?
    /// 브라우저로 나간 직후에도 잠시 살아 있어야 루프백 응답을 받을 수 있다.
    @State private var bgTask: UIBackgroundTaskIdentifier = .invalid

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
                case .waiting: waitingSection
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
        .onDisappear { teardown() }
    }

    // MARK: ① 로그인 / ② 연결 안내

    @ViewBuilder private var introSection: some View {
        Text(loc.browserStepLogin)
            .font(.term(13)).foregroundStyle(Term.fg)
        TerminalButton(title: loc.browserLoginOpen, color: Term.cyan) {
            // 로그인만 시킨다 — 인가 파라미터가 없으니 앱은 아무것도 기다리지 않는다.
            openURL(ClaudeOAuth.loginURL)
        }

        Text(loc.browserStepConnect)
            .font(.term(13)).foregroundStyle(Term.fg)
            .padding(.top, 6)
        TerminalButton(title: loc.browserConnectStart, color: Term.green) {
            Task { await startConnect() }
        }

        manualEntryLink
    }

    // MARK: 승인 대기(루프백)

    @ViewBuilder private var waitingSection: some View {
        HStack(spacing: 8) {
            TerminalSpinner(size: 12)
            Text(loc.browserWaiting).font(.term(13)).foregroundStyle(Term.fg)
            Spacer(minLength: 0)
        }
        Text(loc.browserWaitingHint)
            .font(.term(12)).foregroundStyle(Term.dim)
        Text(loc.browserErrorPageNote)
            .font(.term(12)).foregroundStyle(Term.yellow)

        TerminalButton(title: loc.browserReopen, color: Term.cyan) { openAuthorize() }

        manualEntryLink
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
            // 콘솔 코드 페이지로 보낸다(같은 PKCE라 이미 로그인돼 있으면 승인만 하면 된다).
            openURL(ProviderAuth.authorizeURL(provider, pkce: pkce))
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

    // MARK: 동작

    /// ②: 루프백 리스너를 띄우고 인가 URL을 연다. 이 시점부터 앱은 응답을 기다린다.
    private func startConnect() async {
        guard server == nil, stage == .intro else { return }
        inlineError = nil
        let listener = LoopbackCallbackServer(expectedState: pkce.state) { code, state in
            deliver(code: code, state: state, redirect: loopbackRedirect)
        }
        do {
            let port = try await listener.start()
            server = listener
            loopbackRedirect = ClaudeOAuth.loopbackRedirectURI(port: port)
            // 브라우저로 전환한 뒤에도 잠깐 살아 있어야 승인 직후의 리다이렉트에 응답할 수 있다.
            bgTask = BackgroundActivity.begin(name: "oauth-loopback")
            stage = .waiting
            openAuthorize()
        } catch {
            // 리스너를 못 띄우면 자동 수신은 불가능하다 — 붙여넣기 흐름으로 전환한다.
            listener.stop()
            stage = .manual
            inlineError = loc.browserOpenFailed
        }
    }

    private func openAuthorize() {
        openURL(ProviderAuth.authorizeURL(provider, pkce: pkce, redirect: loopbackRedirect))
    }

    private func submitManual() {
        inlineError = nil
        guard let parsed = ClaudeOAuth.parseManualCode(codeText, fallbackState: pkce.state) else {
            AnalyticsService.shared.log(.loginFail(provider: provider, stage: .codeEntry, code: "code_parse"))
            inlineError = loc.errCodeInvalid
            return
        }
        // 콘솔 콜백으로 발급된 코드라 교환도 그 redirect_uri로 해야 한다.
        deliver(code: parsed.code, state: parsed.state, redirect: nil)
    }

    private func deliver(code: String, state: String, redirect: String?) {
        teardown()
        onCode(code, state, redirect ?? ClaudeOAuth.redirectURI)
    }

    private func teardown() {
        server?.stop()
        server = nil
        BackgroundActivity.end(bgTask)
        bgTask = .invalid
    }
}

// MARK: - 디바이스 플로우 화면

/// OAuth device flow: user code 발급 → 브라우저 승인 → 토큰 폴링.
/// (현재 소비자는 GitHub Copilot 하나라 `CopilotDeviceFlow`를 직접 호출한다.
///  두 번째 device-flow provider가 생기면 ProviderAuth로 디스패치를 일반화한다.)
private struct DeviceFlowView: View {
    let provider: AgentProvider
    let loc: L10n
    let onComplete: (OAuthTokens) -> Void
    let onError: (String) -> Void

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

                    if let uri = verificationURI {
                        Link(destination: uri) {
                            Text(loc.deviceFlowOpen)
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
            let device = try await CopilotDeviceFlow.requestDeviceCode()
            userCode = device.userCode
            verificationURI = device.verificationURI
            let tokens = try await CopilotDeviceFlow.pollForToken(device)
            onComplete(tokens)
        } catch is CancellationError {
            // 화면 이탈로 취소됨 — 무시.
        } catch {
            onError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

#Preview {
    AddAgentSheet().environment(AgentStore())
}
