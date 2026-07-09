//
//  TokenStore.swift
//  TokenWatch
//
//  에이전트별 OAuth 토큰을 Keychain에 저장/로드하고, 만료 시 자동 갱신해
//  유효한 access token을 제공한다.
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

    /// 유효한 access token을 반환. 만료됐고 refresh token이 있으면 갱신 후 저장.
    func validAccessToken(for agentID: UUID) async throws -> String {
        guard var tokens = tokens(for: agentID) else { throw OAuthError.notAuthenticated }
        if tokens.isExpired {
            guard let refresh = tokens.refreshToken else { throw OAuthError.notAuthenticated }
            tokens = try await ClaudeOAuth.refresh(refresh, scopes: tokens.scopes, previous: tokens)
            save(tokens, for: agentID)
        }
        return tokens.accessToken
    }
}
