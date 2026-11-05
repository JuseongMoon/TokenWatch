//
//  AuthTestSupport.swift
//  TokenWatchTests
//
//  인증 회귀 테스트 공용 부품 — 실제 Keychain·네트워크 없이 완료 순서를 통제한다.
//  모든 값은 합성 값이다(실제 토큰·키·계정 아님).
//

import Foundation
@testable import TokenWatch

/// 메모리 자격증명 저장소. `failWrites`로 저장 실패를 흉내 낸다.
final class MemoryCredentialStorage: CredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UUID: OAuthTokens] = [:]
    private var _failWrites = false
    private var _writeCount = 0

    var failWrites: Bool {
        get { lock.withLock { _failWrites } }
        set { lock.withLock { _failWrites = newValue } }
    }
    var writeCount: Int { lock.withLock { _writeCount } }

    func read(_ agentID: UUID) -> OAuthTokens? { lock.withLock { items[agentID] } }

    func write(_ tokens: OAuthTokens, for agentID: UUID) -> Bool {
        lock.withLock {
            guard !_failWrites else { return false }
            items[agentID] = tokens
            _writeCount += 1
            return true
        }
    }

    func remove(_ agentID: UUID) { lock.withLock { items[agentID] = nil } }

    /// 테스트 준비용 직접 기록(세대·실패 플래그와 무관).
    func seed(_ tokens: OAuthTokens, for agentID: UUID) { lock.withLock { items[agentID] = tokens } }
}

/// 갱신 요청을 붙잡아 두었다가 테스트가 정한 순서·결과로 끝내는 가짜 refresher.
actor ScriptedRefresher {
    private var waiters: [CheckedContinuation<Result<OAuthTokens, Error>, Never>] = []
    private(set) var received: [OAuthTokens] = []
    /// 설정하면 붙잡지 않고 즉시 이 결과로 끝낸다.
    private var immediate: Result<OAuthTokens, Error>?

    init(immediate: Result<OAuthTokens, Error>? = nil) { self.immediate = immediate }

    var callCount: Int { received.count }

    func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        received.append(tokens)
        if let immediate { return try immediate.get() }
        let result = await withCheckedContinuation { waiters.append($0) }
        return try result.get()
    }

    /// 가장 먼저 붙잡힌 요청을 끝낸다.
    func completeNext(_ result: Result<OAuthTokens, Error>) {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume(returning: result)
    }

    var pendingCount: Int { waiters.count }
}

/// 조회를 붙잡아 두었다가 테스트가 정한 순서·결과로 끝내는 가짜 스냅샷 조회.
@MainActor
final class ScriptedFetcher {
    private var waiters: [CheckedContinuation<AgentSnapshot?, Never>] = []
    private(set) var callCount = 0

    func fetch() async -> AgentSnapshot? {
        callCount += 1
        return await withCheckedContinuation { waiters.append($0) }
    }

    var pendingCount: Int { waiters.count }

    func completeNext(_ snapshot: AgentSnapshot?) {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume(returning: snapshot)
    }
}

enum AuthFixtures {
    static func oauth(access: String, refresh: String?, expired: Bool = true,
                      email: String? = nil, plan: String? = nil, userID: String? = nil) -> OAuthTokens {
        var t = OAuthTokens(accessToken: access, refreshToken: refresh,
                            expiresAt: expired ? Date(timeIntervalSinceNow: -3600) : Date(timeIntervalSinceNow: 3600),
                            scopes: [], accountEmail: email, plan: plan)
        t.stableUserID = userID
        return t
    }

    static func okSnapshot(_ label: String = "Credits") -> AgentSnapshot {
        AgentSnapshot(windows: [UsageWindow(label: label, usedPercent: 0, resetsAt: nil, kind: .weekly,
                                            style: .balance, valueText: "1.00 credits left",
                                            balanceRemaining: 1, balanceTotal: 2)],
                      planLabel: nil, fetchedAt: Date(), error: nil)
    }

    static func errorSnapshot(_ message: String = "synthetic auth error") -> AgentSnapshot {
        AgentSnapshot(windows: [], planLabel: nil, fetchedAt: Date(), error: message, errorReason: .auth)
    }

    /// 격리된 UserDefaults(실제 앱 저장 데이터를 건드리지 않는다).
    static func isolatedDefaults() -> UserDefaults {
        let name = "TokenWatchTests.auth.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// AgentStore가 읽는 저장 목록에 카드를 미리 넣는다.
    static func seedAgents(_ agents: [Agent], into defaults: UserDefaults) {
        defaults.set(try! JSONEncoder().encode(agents), forKey: "tokenwatch.agents.v1")
    }
}

/// 조건이 참이 될 때까지 잠깐 기다린다(최대 약 3초). 시간이 다 되면 그냥 돌아온다 — 뒤의 단언이 실패를 드러낸다.
func eventually(_ condition: () async -> Bool) async {
    for _ in 0..<150 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}
