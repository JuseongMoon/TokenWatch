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

    private enum Phase: Equatable {
        case pickProvider
        case login(AgentProvider)
        case exchanging
        case failed(String)
    }

    @State private var phase: Phase = .pickProvider
    @State private var pkce = PKCE()

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
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("[esc]")
                            .font(.term(13, weight: .semibold))
                            .foregroundStyle(Term.dim)
                    }
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
                            pkce = PKCE()
                            phase = .login(provider)
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

#Preview {
    AddAgentSheet().environment(AgentStore())
}
