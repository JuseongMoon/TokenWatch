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

    /// provider별 서비스 운영 상태(정상/장애/점검). 사용량과 별개 축이라 provider 단위로
    /// 캐시한다. 엔드포인트가 없는 provider(OpenRouter·Grok·Leonardo)는 키가 없으며,
    /// UI는 그 경우를 "알 수 없음"으로 취급한다.
    private(set) var serviceStatus: [AgentProvider: ServiceHealth] = [:]
    /// provider별 마지막 상태 조회 시각 — 짧은 간격 중복 조회를 막는 스로틀 기준.
    @ObservationIgnored private var statusFetchedAt: [AgentProvider: Date] = [:]
    /// 상태 재조회 최소 간격(초). 사용량 폴링(최소 30초)과 무관하게 상태는 이 간격으로만 갱신.
    @ObservationIgnored private let statusMinInterval: TimeInterval = 60

    /// 에이전트별 마지막 조회 시작 시각 — 짧은 간격 중복/버스트 조회를 막는 스로틀 기준.
    @ObservationIgnored private var lastFetchAt: [UUID: Date] = [:]
    /// 사용량 재조회 최소 간격(초). 최소 폴링 하한(30초)보다 낮게 둬 정상 폴링은 막지 않고
    /// 포그라운드 재진입/중복 트리거 버스트만 흡수한다.
    @ObservationIgnored private let minFetchSpacing: TimeInterval = 20

    private let defaultsKey = "tokenwatch.agents.v1"
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?

    /// Auto 모드의 현재 사다리 인덱스. 관찰 대상이라 설정 화면의 "현재 간격" 표기가 따라간다.
    /// 세션(메모리) 한정 — 앱 재실행 시 기본 60초에서 다시 시작한다.
    private var autoLadderIndex = AutoRefreshPolicy.baseIndex
    /// Auto 모드 변화량 비교 기준점: "에이전트UUID|창라벨" -> usedPercent.
    @ObservationIgnored private var autoBaseline: [String: Double] = [:]
    /// 다음 리셋 시각(+여유)에 맞춘 1회성 추가 새로고침 태스크와 그 목표 시각.
    @ObservationIgnored private var resetRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var scheduledResetRefreshAt: Date?

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
        // 이미 조회 중이면 중복 실행 방지.
        guard !loadingIDs.contains(agent.id) else { return }
        // 최근 minFetchSpacing 안에 이미 조회했으면 캐시 유지(버스트 흡수).
        if let last = lastFetchAt[agent.id],
           Date().timeIntervalSince(last) < minFetchSpacing { return }
        lastFetchAt[agent.id] = Date()
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

        // 새 스냅샷이 반영됐으니 다음 리셋 시각의 추가 새로고침을 재예약한다.
        scheduleResetRefresh()

        // 서비스 운영 상태도 함께 최신화(스로틀 — 실제 조회는 최소 간격마다 한 번).
        await refreshStatus(for: agent.provider)
    }

    // MARK: 서비스 운영 상태 조회

    /// provider의 상태 페이지 JSON을 조회해 serviceStatus를 갱신한다.
    /// - 엔드포인트가 없는 provider는 즉시 반환(항상 "알 수 없음"으로 남는다).
    /// - force가 아니면 statusMinInterval 안에는 재조회하지 않는다.
    /// - 조회 실패는 ServiceStatusClient가 .unknown으로 흡수한다(예외 없음).
    func refreshStatus(for provider: AgentProvider, force: Bool = false) async {
        guard let source = provider.statusSource else { return }
        let now = Date()
        if !force, let last = statusFetchedAt[provider],
           now.timeIntervalSince(last) < statusMinInterval { return }
        // await 전에 시각을 먼저 찍어, 동시에 여러 에이전트가 같은 provider를 조회할 때
        // 중복 요청을 막는다.
        statusFetchedAt[provider] = now
        let health = await ServiceStatusClient.fetch(source)
        serviceStatus[provider] = health
    }

    // MARK: 자동 새로고침 (포그라운드 전용)

    /// interval 초마다 전 에이전트를 갱신. interval == 0 이면 즉시 1회만 하고 루프 없음.
    /// interval == AutoRefreshPolicy.sentinel(-1) 이면 Auto 모드: 사용량 변화 속도에
    /// 따라 AutoRefreshPolicy.ladder 안에서 간격을 스스로 조절한다.
    func startAutoRefresh(interval: Int) {
        autoRefreshTask?.cancel()
        let adaptive = (interval == AutoRefreshPolicy.sentinel)
        autoRefreshTask = Task { [weak self] in
            guard let self else { return }
            // 진입 즉시 1회. Auto면 이 결과가 변화량 비교의 기준점이 된다.
            await self.refreshAll()
            if adaptive { self.autoBaseline = self.gaugePercents() }
            guard adaptive || interval > 0 else { return }
            while !Task.isCancelled {
                let seconds = adaptive ? self.autoIntervalSeconds : interval
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { break }
                await self.refreshAll()
                if adaptive { self.adaptAutoInterval() }
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        resetRefreshTask?.cancel()
        resetRefreshTask = nil
        scheduledResetRefreshAt = nil
    }

    // MARK: Auto(적응형) 간격 조절

    /// Auto 모드의 현재 유효 간격(초). 설정 화면 "현재 간격" 표기용.
    var autoIntervalSeconds: Int { AutoRefreshPolicy.ladder[autoLadderIndex] }

    /// 이번 주기의 게이지 사용률을 직전 기준점과 비교해 간격을 조절한다.
    private func adaptAutoInterval() {
        let current = gaugePercents()
        let delta = AutoRefreshPolicy.maxUsageDelta(from: autoBaseline, to: current)
        // 에러로 빠진 창의 기준점은 남겨 두어(merge) 다음 성공 때 이어서 비교한다.
        autoBaseline.merge(current) { _, new in new }
        autoLadderIndex = AutoRefreshPolicy.nextLadderIndex(from: autoLadderIndex, maxDelta: delta)
    }

    /// 에러 없는 스냅샷의 게이지 창 사용률 맵. key = "에이전트UUID|창라벨".
    /// balance(잔액형) 창은 usedPercent가 항상 0이라 변화 신호가 없으므로 제외한다.
    private func gaugePercents() -> [String: Double] {
        var out: [String: Double] = [:]
        for (id, snap) in snapshots where snap.error == nil {
            for w in snap.windows where w.style == .gauge {
                out["\(id.uuidString)|\(w.label)"] = w.usedPercent
            }
        }
        return out
    }

    // MARK: 리셋 시각 추가 새로고침

    /// 가장 이른 미래 리셋 시각 + 여유(1초)에 전체 새로고침 1회를 예약한다.
    /// 자동 새로고침이 살아 있는 동안(포그라운드)만 걸고, 목표 시각이 바뀔 때만 다시 건다.
    /// 발화 후에는 refreshAll → refresh 꼬리의 재호출이 다음 리셋을 이어서 예약한다.
    private func scheduleResetRefresh(now: Date = Date()) {
        guard autoRefreshTask != nil else { return }
        let target = AutoRefreshPolicy.nextResetDate(in: Array(snapshots.values), after: now)?
            .addingTimeInterval(AutoRefreshPolicy.resetSlack)
        guard target != scheduledResetRefreshAt else { return }
        resetRefreshTask?.cancel()
        scheduledResetRefreshAt = target
        guard let target else { return }
        resetRefreshTask = Task { [weak self] in
            let delay = target.timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, !Task.isCancelled else { return }
            // refreshAll 꼬리의 재예약이 실행 중인 이 태스크를 취소하지 않도록 먼저 비운다.
            self.resetRefreshTask = nil
            self.scheduledResetRefreshAt = nil
            await self.refreshAll()
        }
    }
}

// MARK: - Auto 새로고침 정책(순수 로직)

/// Auto(적응형) 새로고침의 순수 정책 — AgentStore와 단위 테스트가 공유한다.
/// 목표: "새로고침 한 번에 1~2%p 변화가 보이는" 간격으로 수렴시키는 것.
/// 같은 소비 속도라도 간격이 짧아지면 회당 변화폭이 줄어들므로, 이 기준 자체가
/// 자연스러운 브레이크가 되어 최소 간격까지는 아주 빠른 소비에서만 내려간다.
enum AutoRefreshPolicy {
    /// Auto 모드를 뜻하는 refreshInterval 저장값. RefreshInterval.auto.rawValue와 같아야 한다.
    static let sentinel = -1

    /// Auto 모드가 오가는 간격 사다리(초).
    /// - 최소 30초: Claude oauth/usage가 공격적으로 429를 던지므로(RateLimitGate 참고)
    ///   기존 고정 옵션의 최솟값(30s)을 하한으로 유지한다 — 이미 검증된 값.
    /// - 최대 600초: 포그라운드 방치 시 배터리·API 절약. 리셋 순간의 갱신은
    ///   리셋 시각 추가 새로고침이 따로 보장하므로 최대 10분 지연을 감수할 수 있다.
    static let ladder = [30, 60, 120, 300, 600]

    /// 시작 인덱스 — 60초("1분 업데이트 기반").
    static let baseIndex = 1

    /// 서버 시계 오차에 대비해 리셋 시각 뒤에 두는 여유(초).
    static let resetSlack: TimeInterval = 1

    /// 변화폭(maxDelta, %p)에 따른 다음 사다리 인덱스(작을수록 짧은 간격).
    /// ≥4는 두 단계·≥2는 한 단계 단축, ≤1은 한 단계 연장, (1,2) 구간은 유지(히스테리시스).
    /// nil(겹치는 창 없음·전부 에러)은 현재 유지. 결과는 사다리 범위로 클램프.
    static func nextLadderIndex(from index: Int, maxDelta: Double?) -> Int {
        guard let delta = maxDelta else { return index }
        var next = index
        if delta >= 4 {
            next -= 2
        } else if delta >= 2 {
            next -= 1
        } else if delta <= 1 {
            next += 1
        }
        return min(max(next, 0), ladder.count - 1)
    }

    /// 두 사용률 맵에서 같은 창끼리의 증가폭(%p) 중 최댓값.
    /// 리셋 등으로 감소한 창은 0으로 취급하고, 겹치는 창이 없으면 nil(신호 없음).
    static func maxUsageDelta(from old: [String: Double], to new: [String: Double]) -> Double? {
        var best: Double?
        for (key, value) in new {
            guard let prev = old[key] else { continue }
            best = max(best ?? 0, value - prev)
        }
        return best.map { max($0, 0) }
    }

    /// 스냅샷들의 모든 창 중 now 이후(엄격히 미래)에 오는 가장 이른 리셋 시각.
    static func nextResetDate(in snapshots: [AgentSnapshot], after now: Date) -> Date? {
        snapshots.flatMap(\.windows).compactMap(\.resetsAt).filter { $0 > now }.min()
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
