//
//  AddAgentSheet.swift
//  TokenWatch
//
//  + 버튼 시트: 제공자 선택 → OAuth 로그인 → 토큰 교환 → 에이전트 추가.
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
            content
                .navigationTitle("에이전트 추가")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("취소") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .pickProvider:
            providerList
        case .login(let provider):
            loginView(provider)
        case .exchanging:
            VStack(spacing: 16) {
                ProgressView()
                Text("로그인 처리 중…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            failureView(message)
        }
    }

    private var providerList: some View {
        List {
            Section("로그인할 서비스를 선택하세요") {
                ForEach(AgentProvider.allCases) { provider in
                    Button {
                        pkce = PKCE()
                        phase = .login(provider)
                    } label: {
                        HStack {
                            Image(systemName: provider.symbolName)
                                .foregroundStyle(provider.accentColor)
                                .frame(width: 24)
                            Text(provider.displayName)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
                }
            }
        }
    }

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
        .ignoresSafeArea(edges: .bottom)
    }

    private func failureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("로그인 실패", systemImage: "xmark.octagon")
        } description: {
            Text(message)
        } actions: {
            Button("다시 시도") {
                pkce = PKCE()
                phase = .pickProvider
            }
            .buttonStyle(.borderedProminent)
        }
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
