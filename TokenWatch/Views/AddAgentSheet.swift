//
//  AddAgentSheet.swift
//  TokenWatch
//
//  + 버튼 시트(터미널 스타일): 제공자 선택 → OAuth 로그인 → 토큰 교환 → 추가.
//  로그인 단계의 LoginWebView는 외부 OAuth 페이지라 그대로 둔다.
//

import SwiftUI

struct AddAgentSheet: View {
    @Environment(AgentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @AppStorage(appLanguageStorageKey) private var appLanguage: AppLanguage = .system
    private var loc: L10n { L10n(lang: appLanguage.resolved) }

    private enum Phase: Equatable {
        case pickProvider
        case login(AgentProvider)        // oauthCode: WKWebView 콜백 code 캡처
        case apiKey(AgentProvider)       // apiKey: 사용자 키 붙여넣기
        case deviceFlow(AgentProvider)   // oauthDeviceFlow: user code 발급 + 폴링
        case exchanging
        case failed(String)
    }

    @State private var phase: Phase = .pickProvider
    @State private var pkce = PKCE()
    @State private var apiKeyText = ""

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
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .pickProvider:
            providerList
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
                phase = .failed(message)
            }
        )
        .background(Term.bg)
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: 인증 방식 분기

    /// provider의 authKind에 따라 다음 화면을 고른다.
    private func start(_ provider: AgentProvider) {
        switch provider.authKind {
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

                TextField("", text: $apiKeyText,
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
        await store.addAgent(provider: provider, tokens: tokens)
        dismiss()
    }

    // MARK: 디바이스 플로우 (GitHub Copilot 등)

    private func deviceFlowView(_ provider: AgentProvider) -> some View {
        DeviceFlowView(
            provider: provider,
            loc: loc,
            onComplete: { tokens in
                phase = .exchanging
                Task {
                    await store.addAgent(provider: provider, tokens: tokens)
                    dismiss()
                }
            },
            onError: { message in phase = .failed(message) }
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
            TerminalButton(title: "[ RETRY ]", color: Term.green) {
                pkce = PKCE()
                phase = .pickProvider
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func exchange(provider: AgentProvider, code: String, state: String) async {
        do {
            let tokens = try await ProviderAuth.exchange(provider, code: code, state: state, pkce: pkce)
            await store.addAgent(provider: provider, tokens: tokens)
            dismiss()
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .failed(msg)
        }
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
