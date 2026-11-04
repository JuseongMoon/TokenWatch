//
//  TokenStore.swift
//  TokenWatch
//
//  에이전트별 OAuth 토큰을 Keychain에 저장/로드하고, 만료 시 자동 갱신해
//  유효한 토큰을 제공한다.
//
//  ⚠️ refresh token 로테이션 주의 — Claude/Codex/Grok 모두 갱신 응답에 "새" refresh token을
//     실어 보내고 직전 토큰을 무효화한다. 즉 갱신 왕복은 원자적이어야 한다:
//     서버가 로테이션했는데 우리가 새 토큰을 저장하지 못하면 그 자격증명은 영구히 죽는다
//     (이후 모든 갱신이 invalid_grant → 재로그인 외 복구 불가).
//     그래서 갱신은 (1) 취소되지 않는 비구조적 Task 안에서 돌고,
//     (2) agentID당 하나로 합쳐지며(동시 갱신이 같은 토큰을 두 번 쓰지 않게),
//     (3) 백그라운드 전환 중에도 끝나도록 실행 유예를 잡는다.
//
//  ⚠️ 로그인 세대(generation) — actor는 네트워크 `await` 동안 재진입을 허용한다. 갱신 A가 응답을
//     기다리는 사이 같은 카드로 재로그인 B가 저장될 수 있고, 그대로 두면 늦게 끝난 A가
//     B의 토큰을 덮어쓰거나(성공) B의 refresh token을 지운다(영구 실패). 그래서 새 로그인 저장과
//     삭제는 세대를 올리고, 갱신은 시작할 때의 세대가 그대로일 때만 결과를 저장·무효화한다.
//     세대가 바뀐 갱신 결과는 버리고 호출자에게 `CredentialSuperseded`를 던진다(옛 토큰을 돌려주지 않는다).
//     로테이션 저장(persist)과 plan 갱신은 같은 세대 안의 변경이라 세대를 올리지 않는다.
//

import Foundation

/// 진행하던 작업이 시작한 뒤 같은 카드에 새 로그인이 저장되거나 카드가 삭제됐다 — 결과를 버려야 한다.
/// 에러가 아니라 취소에 가깝다(표시 상태를 건드리지 않는다).
nonisolated struct CredentialSuperseded: Error, Equatable {}

/// 자격증명 저장소 경계. 앱은 Keychain, 테스트는 메모리 구현을 쓴다.
nonisolated protocol CredentialStorage: Sendable {
    func read(_ agentID: UUID) -> OAuthTokens?
    /// 저장 성공 여부.
    func write(_ tokens: OAuthTokens, for agentID: UUID) -> Bool
    func remove(_ agentID: UUID)
}

/// 기기 Keychain 저장소(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
nonisolated struct KeychainCredentialStorage: CredentialStorage {
    private func account(for agentID: UUID) -> String { "tokens.\(agentID.uuidString)" }

    func read(_ agentID: UUID) -> OAuthTokens? {
        Keychain.json(OAuthTokens.self, account: account(for: agentID))
    }

    func write(_ tokens: OAuthTokens, for agentID: UUID) -> Bool {
        Keychain.setJSON(tokens, account: account(for: agentID))
    }

    func remove(_ agentID: UUID) {
        Keychain.delete(account: account(for: agentID))
    }
}

actor TokenStore {
    static let shared = TokenStore()

    typealias Refresher = @Sendable (AgentProvider, OAuthTokens) async throws -> OAuthTokens

    private let storage: CredentialStorage
    private let refresher: Refresher

    /// 진행 중인 갱신 — agentID당(같은 세대 안에서) 하나로 합친다(중복 갱신 = 로테이션 충돌).
    private var refreshTasks: [UUID: (generation: UInt64, task: Task<OAuthTokens, Error>)] = [:]
    /// agentID별 로그인 세대. 새 로그인 저장·삭제 때만 오른다. 메모리 한정 —
    /// 진행 중인 갱신도 프로세스 안에만 있으므로 재시작을 넘길 필요가 없다.
    private var generations: [UUID: UInt64] = [:]

    init(storage: CredentialStorage = KeychainCredentialStorage(),
         refresher: @escaping Refresher = { try await ProviderAuth.refresh($0, $1) }) {
        self.storage = storage
        self.refresher = refresher
    }

    // MARK: 세대

    /// 현재 로그인 세대. 조회 한 번을 한 세대에 묶을 때 시작 시점에 읽는다.
    func generation(for agentID: UUID) -> UInt64 { generations[agentID, default: 0] }

    private func bumpGeneration(_ agentID: UUID) {
        generations[agentID, default: 0] &+= 1
    }

    private func ensureGeneration(_ expected: UInt64?, for agentID: UUID) throws {
        if let expected, expected != generation(for: agentID) { throw CredentialSuperseded() }
    }

    // MARK: 저장 / 로드

    /// 같은 세대 안의 저장(로테이션 결과 등). 새 로그인은 `replaceLogin`을 쓴다.
    /// 저장 성공 여부를 돌려준다.
    @discardableResult
    func save(_ tokens: OAuthTokens, for agentID: UUID) -> Bool {
        storage.write(tokens, for: agentID)
    }

    /// 새 로그인(최초 추가·같은 계정 재로그인)의 토큰 저장. 저장에 성공했을 때만 세대를 올려
    /// 진행 중인 이전 세대의 갱신·조회 결과가 이 토큰을 덮거나 지우지 못하게 한다.
    /// 저장에 실패하면 세대를 그대로 둔다(기존 자격증명의 정상 갱신을 불필요하게 무효화하지 않는다).
    @discardableResult
    func replaceLogin(_ tokens: OAuthTokens, for agentID: UUID) -> Bool {
        guard storage.write(tokens, for: agentID) else { return false }
        bumpGeneration(agentID)
        return true
    }

    func tokens(for agentID: UUID) -> OAuthTokens? {
        storage.read(agentID)
    }

    func delete(for agentID: UUID) {
        bumpGeneration(agentID)
        storage.remove(agentID)
        refreshTasks[agentID]?.task.cancel()
        refreshTasks[agentID] = nil
    }

    /// 저장된 토큰의 plan만 갱신(라이브 plan 조회 결과 반영). 토큰이 없으면 무시.
    /// - Parameter generation: 이 plan을 읽어 온 조회의 세대. 그 사이 새 로그인이 저장됐으면 무시한다.
    func updatePlan(_ plan: String, for agentID: UUID, generation: UInt64? = nil) {
        if let generation, generation != self.generation(for: agentID) { return }
        guard var t = tokens(for: agentID) else { return }
        t.plan = plan
        save(t, for: agentID)
    }

    /// 저장된 토큰의 provider 사용자 ID만 채운다(레거시 자격증명 보강). 같은 세대일 때만.
    func updateStableUserID(_ id: String, for agentID: UUID, generation: UInt64? = nil) {
        if let generation, generation != self.generation(for: agentID) { return }
        guard var t = tokens(for: agentID), t.stableUserID == nil else { return }
        t.stableUserID = id
        save(t, for: agentID)
    }

    /// 유효한 토큰을 반환. 만료됐고 refresh token이 있으면 갱신 후 저장.
    /// - Parameter generation: 조회를 시작한 세대. 다르면 `CredentialSuperseded`.
    func validTokens(for agentID: UUID, provider: AgentProvider,
                     generation: UInt64? = nil) async throws -> OAuthTokens {
        try ensureGeneration(generation, for: agentID)
        guard let tokens = tokens(for: agentID) else { throw OAuthError.notAuthenticated }
        guard tokens.isExpired else { return tokens }
        guard tokens.refreshToken != nil else { throw OAuthError.notAuthenticated }
        return try await refreshShared(for: agentID, provider: provider)
    }

    /// 서버가 401을 준 경우: 만료 여부와 무관하게 강제 갱신 후 저장.
    func forceRefresh(for agentID: UUID, provider: AgentProvider,
                      generation: UInt64? = nil) async throws -> OAuthTokens {
        try ensureGeneration(generation, for: agentID)
        guard let tokens = tokens(for: agentID), tokens.refreshToken != nil else {
            throw OAuthError.notAuthenticated
        }
        return try await refreshShared(for: agentID, provider: provider)
    }

    // MARK: 갱신 (로테이션 안전)

    /// agentID당 갱신을 하나로 합쳐 실행한다. 같은 세대의 갱신이 진행 중이면 그 결과를 함께 기다린다.
    ///
    /// 갱신 본체는 비구조적 `Task`라서 호출자가 취소돼도(백그라운드 전환으로 자동
    /// 새로고침 태스크가 취소되거나 BGAppRefreshTask 시간이 만료돼도) 끝까지 진행해
    /// 로테이션된 새 refresh token을 반드시 Keychain에 남긴다.
    /// 단 그 사이 새 로그인이 저장됐거나 카드가 삭제됐으면(세대 변경) 결과를 저장·무효화하지 않고 버린다.
    private func refreshShared(for agentID: UUID, provider: AgentProvider) async throws -> OAuthTokens {
        let gen = generation(for: agentID)
        if let existing = refreshTasks[agentID], existing.generation == gen {
            return try await existing.task.value
        }
        let refresher = self.refresher
        let task = Task { () throws -> OAuthTokens in
            // 백그라운드로 나가는 도중에도 왕복을 마치도록 실행 유예를 잡는다.
            let activity = await BackgroundActivity.begin(name: "token-refresh")
            defer { Task { await BackgroundActivity.end(activity) } }

            // 갱신 직전에 최신 저장본을 다시 읽는다(앞선 갱신이 방금 로테이션했을 수 있다).
            // 실행 유예를 잡는 사이 세대가 바뀌었으면 이 갱신은 시작하지 않는다.
            guard self.generation(for: agentID) == gen else { throw CredentialSuperseded() }
            guard let current = self.tokens(for: agentID), let usedRefresh = current.refreshToken else {
                throw OAuthError.notAuthenticated
            }
            do {
                let new = try await refresher(provider, current)
                // 응답을 기다리는 사이 새 로그인·삭제가 있었다 — 그 자격증명을 덮지 않는다.
                // (확인과 저장 사이에 await가 없어 actor 안에서 원자적이다.)
                guard self.generation(for: agentID) == gen else { throw CredentialSuperseded() }
                self.persist(new, for: agentID)
                return new
            } catch OAuthError.refreshRevoked {
                // 되살릴 수 없는 자격증명 — 죽은 토큰으로 매 틱 400을 두드리지 않도록
                // refresh token을 지워 이후에는 곧바로 "재로그인 필요"로 떨어지게 한다.
                // 단 거부된 것이 지금 저장된(같은 세대의, 같은) refresh token일 때만 지운다.
                guard self.generation(for: agentID) == gen else { throw CredentialSuperseded() }
                self.invalidateRefreshToken(for: agentID, ifMatching: usedRefresh)
                throw OAuthError.refreshRevoked
            }
        }
        refreshTasks[agentID] = (gen, task)
        defer {
            // 끝난 뒤 이 세대의 항목만 정리한다 — 그 사이 생긴 새 세대의 갱신을 지우지 않는다.
            if refreshTasks[agentID]?.generation == gen { refreshTasks[agentID] = nil }
        }
        return try await task.value
    }

    /// 로테이션된 토큰 저장 — 실패하면 한 번 더 시도한다. 여기서 놓치면 자격증명이 죽는다.
    private func persist(_ tokens: OAuthTokens, for agentID: UUID) {
        if save(tokens, for: agentID) { return }
        _ = save(tokens, for: agentID)
    }

    /// 서버가 거부한 refresh token을 저장본에서 제거(access token은 남겨둔다 — 만료 전까지는
    /// 조회가 될 수도 있고, 계정 이메일/플랜 표시도 유지된다).
    private func invalidateRefreshToken(for agentID: UUID, ifMatching rejected: String) {
        guard var t = tokens(for: agentID), t.refreshToken == rejected else { return }
        t.refreshToken = nil
        save(t, for: agentID)
    }
}
