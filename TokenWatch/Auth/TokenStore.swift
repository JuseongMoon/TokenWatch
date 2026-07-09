//
//  TokenStore.swift
//  TokenWatch
//
//  에이전트별 OAuth 토큰을 Keychain에 저장/로드하고, 만료 시 자동 갱신해
//  유효한 토큰을 제공한다.
//

import Foundation

actor TokenStore {
    static let shared = TokenStore()

    private func account(for agentID: UUID) -> String { "tokens.\(agentID.uuidString)" }

    func save(_ tokens: OAuthTokens, for agentID: UUID) {
        Keychain.setJSON(tokens, account: account(for: agentID))
    }

    func tokens(for agentID: UUID) -> OAuthTokens? {
        Keychain.json(OAuthTokens.self, account: account(for: agentID))
    }

    func delete(for agentID: UUID) {
        Keychain.delete(account: account(for: agentID))
    }

    /// 유효한 토큰을 반환. 만료됐고 refresh token이 있으면 갱신 후 저장.
    func validTokens(for agentID: UUID, provider: AgentProvider) async throws -> OAuthTokens {
        guard var tokens = tokens(for: agentID) else { throw OAuthError.notAuthenticated }
        if tokens.isExpired {
            guard tokens.refreshToken != nil else { throw OAuthError.notAuthenticated }
            tokens = try await ProviderAuth.refresh(provider, tokens)
            save(tokens, for: agentID)
        }
        return tokens
    }

    /// 서버가 401을 준 경우: 만료 여부와 무관하게 강제 갱신 후 저장.
    func forceRefresh(for agentID: UUID, provider: AgentProvider) async throws -> OAuthTokens {
        guard let tokens = tokens(for: agentID), tokens.refreshToken != nil else {
            throw OAuthError.notAuthenticated
        }
        let new = try await ProviderAuth.refresh(provider, tokens)
        save(new, for: agentID)
        return new
    }
}
