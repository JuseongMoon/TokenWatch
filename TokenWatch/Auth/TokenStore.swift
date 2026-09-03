//
//  TokenStore.swift
//  TokenWatch
//
//  에이전트별 OAuth 토큰을 Keychain에 저장/로드하고, 만료 시 자동 갱신해
//  유효한 토큰을 제공한다.
//
//  ⚠️ refresh token 로테이션 주의 — Claude/Codex 모두 갱신 응답에 "새" refresh token을
//     실어 보내고 직전 토큰을 무효화한다. 즉 갱신 왕복은 원자적이어야 한다:
//     서버가 로테이션했는데 우리가 새 토큰을 저장하지 못하면 그 자격증명은 영구히 죽는다
//     (이후 모든 갱신이 invalid_grant → 재로그인 외 복구 불가).
//     그래서 갱신은 (1) 취소되지 않는 비구조적 Task 안에서 돌고,
//     (2) agentID당 하나로 합쳐지며(동시 갱신이 같은 토큰을 두 번 쓰지 않게),
//     (3) 백그라운드 전환 중에도 끝나도록 실행 유예를 잡는다.
//

import Foundation

actor TokenStore {
    static let shared = TokenStore()

    /// 진행 중인 갱신 — agentID당 하나로 합친다(중복 갱신 = 로테이션 충돌).
    private var refreshTasks: [UUID: Task<OAuthTokens, Error>] = [:]

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
        refreshTasks[agentID]?.cancel()
        refreshTasks[agentID] = nil
    }

    /// 저장된 토큰의 plan만 갱신(라이브 plan 조회 결과 반영). 토큰이 없으면 무시.
    func updatePlan(_ plan: String, for agentID: UUID) {
        guard var t = tokens(for: agentID) else { return }
        t.plan = plan
        save(t, for: agentID)
    }

    /// 유효한 토큰을 반환. 만료됐고 refresh token이 있으면 갱신 후 저장.
    func validTokens(for agentID: UUID, provider: AgentProvider) async throws -> OAuthTokens {
        guard let tokens = tokens(for: agentID) else { throw OAuthError.notAuthenticated }
        guard tokens.isExpired else { return tokens }
        guard tokens.refreshToken != nil else { throw OAuthError.notAuthenticated }
        return try await refreshShared(for: agentID, provider: provider)
    }

    /// 서버가 401을 준 경우: 만료 여부와 무관하게 강제 갱신 후 저장.
    func forceRefresh(for agentID: UUID, provider: AgentProvider) async throws -> OAuthTokens {
        guard let tokens = tokens(for: agentID), tokens.refreshToken != nil else {
            throw OAuthError.notAuthenticated
        }
        return try await refreshShared(for: agentID, provider: provider)
    }

    // MARK: 갱신 (로테이션 안전)

    /// agentID당 갱신을 하나로 합쳐 실행한다. 이미 진행 중이면 그 결과를 함께 기다린다.
    ///
    /// 갱신 본체는 비구조적 `Task`라서 호출자가 취소돼도(백그라운드 전환으로 자동
    /// 새로고침 태스크가 취소되거나 BGAppRefreshTask 시간이 만료돼도) 끝까지 진행해
    /// 로테이션된 새 refresh token을 반드시 Keychain에 남긴다.
    private func refreshShared(for agentID: UUID, provider: AgentProvider) async throws -> OAuthTokens {
        if let existing = refreshTasks[agentID] {
            return try await existing.value
        }
        let task = Task { () throws -> OAuthTokens in
            // 백그라운드로 나가는 도중에도 왕복을 마치도록 실행 유예를 잡는다.
            let activity = await BackgroundActivity.begin(name: "token-refresh")
            defer { Task { await BackgroundActivity.end(activity) } }

            // 갱신 직전에 최신 저장본을 다시 읽는다(앞선 갱신이 방금 로테이션했을 수 있다).
            guard let current = self.tokens(for: agentID), current.refreshToken != nil else {
                throw OAuthError.notAuthenticated
            }
            do {
                let new = try await ProviderAuth.refresh(provider, current)
                self.persist(new, for: agentID)
                return new
            } catch OAuthError.refreshRevoked {
                // 되살릴 수 없는 자격증명 — 죽은 토큰으로 매 틱 400을 두드리지 않도록
                // refresh token을 지워 이후에는 곧바로 "재로그인 필요"로 떨어지게 한다.
                self.invalidateRefreshToken(for: agentID)
                throw OAuthError.refreshRevoked
            }
        }
        refreshTasks[agentID] = task
        defer { refreshTasks[agentID] = nil }
        return try await task.value
    }

    /// 로테이션된 토큰 저장 — 실패하면 한 번 더 시도한다. 여기서 놓치면 자격증명이 죽는다.
    private func persist(_ tokens: OAuthTokens, for agentID: UUID) {
        if save(tokens, for: agentID) { return }
        _ = save(tokens, for: agentID)
    }

    /// 서버가 거부한 refresh token을 저장본에서 제거(access token은 남겨둔다 — 만료 전까지는
    /// 조회가 될 수도 있고, 계정 이메일/플랜 표시도 유지된다).
    private func invalidateRefreshToken(for agentID: UUID) {
        guard var t = tokens(for: agentID), t.refreshToken != nil else { return }
        t.refreshToken = nil
        save(t, for: agentID)
    }
}
