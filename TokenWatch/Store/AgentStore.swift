//
//  AgentStore.swift
//  TokenWatch
//
//  앱 상태: 추가된 에이전트 목록 + 사용량 스냅샷. 영속화(UserDefaults),
//  수동/자동 새로고침을 담당한다.
//

import Foundation
import SwiftUI

/// 상세 화면에 표시할 계정 정보(Keychain 토큰에서 추출한 스냅샷).
struct AccountInfo: Sendable {
    var email: String?
    var plan: String?
    var scopes: [String]
    var expiresAt: Date?
    var canRefresh: Bool
    var accountId: String?
}

@MainActor
@Observable
final class AgentStore {
    private(set) var agents: [Agent] = []
    private(set) var snapshots: [UUID: AgentSnapshot] = [:]
    private(set) var loadingIDs: Set<UUID> = []

    private let defaultsKey = "tokenwatch.agents.v1"
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?

    init() {
        load()
    }

    // MARK: 영속화

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Agent].self, from: data) else { return }
        agents = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(agents) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    // MARK: 변경

    /// 로그인 성공 후 호출: 토큰을 저장하고 에이전트를 목록에 추가한 뒤 새로고침.
    func addAgent(provider: AgentProvider, tokens: OAuthTokens) async {
        var agent = Agent(provider: provider)
        agent.accountLabel = tokens.accountEmail ?? tokens.plan
        await TokenStore.shared.save(tokens, for: agent.id)
        agents.append(agent)
        persist()
        await refresh(agent)
    }

    func remove(_ agent: Agent) {
        agents.removeAll { $0.id == agent.id }
        snapshots[agent.id] = nil
        persist()
        Task { await TokenStore.shared.delete(for: agent.id) }
    }

    // MARK: 정렬(순서 변경)

    /// 리스트에서 에이전트를 한 칸 위로 이동. 최상단이면 아무 것도 하지 않는다.
    func moveUp(_ agent: Agent) { reorder(agent, by: -1) }

    /// 리스트에서 에이전트를 한 칸 아래로 이동. 최하단이면 아무 것도 하지 않는다.
    func moveDown(_ agent: Agent) { reorder(agent, by: 1) }

    /// 화살표로 지정한 새 순서를 반영하고 영속화한다. 경계를 벗어나면 무시.
    private func reorder(_ agent: Agent, by offset: Int) {
        let next = agents.reordered(movingID: agent.id, by: offset)
        guard next.map(\.id) != agents.map(\.id) else { return }
        agents = next
        persist()
    }

    /// 상세 화면용: Keychain에 저장된 토큰에서 계정 정보를 읽어온다.
    func accountInfo(for agent: Agent) async -> AccountInfo? {
        guard let t = await TokenStore.shared.tokens(for: agent.id) else { return nil }
        return AccountInfo(email: t.accountEmail, plan: t.plan, scopes: t.scopes,
                           expiresAt: t.expiresAt, canRefresh: t.refreshToken != nil,
                           accountId: t.accountId)
    }

    // MARK: 수동 새로고침

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for agent in agents {
                group.addTask { await self.refresh(agent) }
            }
        }
    }

    func refresh(_ agent: Agent) async {
        loadingIDs.insert(agent.id)
        defer { loadingIDs.remove(agent.id) }
        let snapshot = await ProviderUsage.fetchSnapshot(agent.provider, for: agent.id)

        // last-good 유지: 이번 결과가 에러 + 빈 windows인데 이전에 표시하던
        // windows가 있으면, 링/바가 사라지지 않도록 이전 windows를 유지하고
        // 에러만 덧입힌다.
        if snapshot.error != nil, snapshot.windows.isEmpty,
           let prev = snapshots[agent.id], !prev.windows.isEmpty {
            snapshots[agent.id] = AgentSnapshot(
                windows: prev.windows, planLabel: prev.planLabel,
                fetchedAt: prev.fetchedAt, error: snapshot.error)
        } else {
            snapshots[agent.id] = snapshot
        }

        // 플랜 라벨을 얻으면 accountLabel 보강(이메일이 없을 때).
        if let plan = snapshot.planLabel,
           let idx = agents.firstIndex(where: { $0.id == agent.id }),
           (agents[idx].accountLabel ?? "").isEmpty {
            agents[idx].accountLabel = plan
            persist()
        }
    }

    // MARK: 자동 새로고침 (포그라운드 전용)

    /// interval 초마다 전 에이전트를 갱신. interval == 0 이면 즉시 1회만 하고 루프 없음.
    func startAutoRefresh(interval: Int) {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            guard let self else { return }
            // 진입 즉시 1회.
            await self.refreshAll()
            guard interval > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                await self.refreshAll()
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }
}

extension Array where Element: Identifiable {
    /// `id`에 해당하는 원소를 `offset`칸(위로 -1 / 아래로 +1) 옮긴 새 배열을 돌려준다.
    /// 원소가 없거나 이동 위치가 배열 범위를 벗어나면 원본을 그대로 돌려준다.
    /// (AgentStore의 순서 변경과 그 단위 테스트가 공유하는 순수 로직.)
    func reordered(movingID id: Element.ID, by offset: Int) -> [Element] {
        guard let from = firstIndex(where: { $0.id == id }) else { return self }
        let to = from + offset
        guard indices.contains(to) else { return self }
        var copy = self
        copy.swapAt(from, to)
        return copy
    }
}
