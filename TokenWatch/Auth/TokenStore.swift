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

    /// 저장 성공 여부를 돌려준다. 갱신 경로는 무시해도 되지만(메모리 토큰으로 계속 동작),
    /// 최초 로그인 경로는 실패 시 에이전트를 추가하면 안 된다.
    @discardableResult
    func save(_ tokens: OAuthTokens, for agentID: UUID) -> Bool {
        Keychain.setJSON(tokens, account: account(for: agentID))
    }

    func tokens(for agentID: UUID) -> OAuthTokens? {
        Keychain.json(OAuthTokens.self, account: account(for: agentID))
    }

    func delete(for agentID: UUID) {
        Keychain.delete(account: account(for: agentID))
    }

    /// 저장된 토큰의 plan만 갱신(라이브 plan 조회 결과 반영). 토큰이 없으면 무시.
    func updatePlan(_ plan: String, for agentID: UUID) {
        guard var t = tokens(for: agentID) else { return }
        t.plan = plan
        save(t, for: agentID)
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
