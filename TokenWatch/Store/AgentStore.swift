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
    /// provider별 마지막 "성공한" 상태 조회 시각 — 짧은 간격 중복 조회를 막는 스로틀 기준.
    /// 실패한 조회는 여기 찍지 않으므로, 일시적 실패 후 다음 주기에 곧바로 재시도된다.
    @ObservationIgnored private var statusFetchedAt: [AgentProvider: Date] = [:]
    /// 현재 상태를 조회 중인 provider — 동시 중복 요청을 막는 in-flight 가드.
    /// (스로틀을 성공 시에만 찍으므로, 같은 provider의 병렬 호출 억제는 이쪽이 담당.)
    @ObservationIgnored private var statusInFlight: Set<AgentProvider> = []
    /// 상태 재조회 최소 간격(초). 사용량 폴링(최소 30초)과 무관하게 상태는 이 간격으로만 갱신.
    @ObservationIgnored private let statusMinInterval: TimeInterval = 60

    /// 에이전트별 마지막 조회 시작 시각 — 짧은 간격 중복/버스트 조회를 막는 스로틀 기준.
    @ObservationIgnored private var lastFetchAt: [UUID: Date] = [:]
    /// 사용량 재조회 최소 간격(초). 최소 폴링 하한(30초)보다 낮게 둬 정상 폴링은 막지 않고
    /// 포그라운드 재진입/중복 트리거 버스트만 흡수한다.
    @ObservationIgnored private let minFetchSpacing: TimeInterval = 20

    private let defaultsKey = "tokenwatch.agents.v1"
    private let creditPeaksKey = "tokenwatch.creditPeaks.v1"
    private let resetBaselineKey = "tokenwatch.resetBaseline.v1"
    /// 충전형 창의 관측 최고 잔액. key = "에이전트UUID|창라벨". API가 총액을 안 주는 provider의
    /// 게이지 분모 추정에 쓴다. (영속 — 세션 간 유지해야 추정이 안정적.)
    @ObservationIgnored private var creditPeaks: [String: Double] = [:]
    /// 리셋 감지용 창별 마지막 관측(resetsAt·usedPercent). key = "에이전트UUID|창라벨".
    /// (영속 — 앱 재시작·업데이트를 넘어 유지해야 정시 리셋 재감지를 억제할 수 있다.)
    @ObservationIgnored private var resetBaseline: [String: WindowObservation] = [:]
    /// 예약 재조정 재진입 가드 — refreshAll의 병렬 refresh가 pending 조회를 인터리브하지 않게.
    @ObservationIgnored private var rescheduleInFlight = false
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?

    /// Auto 모드의 현재 사다리 인덱스. 관찰 대상이라 설정 화면의 "현재 간격" 표기가 따라간다.
    /// 세션(메모리) 한정 — 앱 재실행, 그리고 Auto 진입/재진입(startAutoRefresh)마다 기본 60초로 리셋.
    private var autoLadderIndex = AutoRefreshPolicy.baseIndex
    /// Auto 모드 변화량 비교 기준점: "에이전트UUID|창라벨" -> usedPercent.
    @ObservationIgnored private var autoBaseline: [String: Double] = [:]
    /// 다음 리셋 시각(+여유)에 맞춘 1회성 추가 새로고침 태스크와 그 목표 시각.
    @ObservationIgnored private var resetRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var scheduledResetRefreshAt: Date?

    init() {
        load()
        creditPeaks = loadCreditPeaks()
        resetBaseline = loadResetBaseline()
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

    private func loadCreditPeaks() -> [String: Double] {
        guard let data = UserDefaults.standard.data(forKey: creditPeaksKey),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return decoded
    }

    private func saveCreditPeaks(_ peaks: [String: Double]) {
        guard let data = try? JSONEncoder().encode(peaks) else { return }
        UserDefaults.standard.set(data, forKey: creditPeaksKey)
    }

    private func loadResetBaseline() -> [String: WindowObservation] {
        guard let data = UserDefaults.standard.data(forKey: resetBaselineKey),
              let decoded = try? JSONDecoder().decode([String: WindowObservation].self, from: data) else { return [:] }
        return decoded
    }

    private func saveResetBaseline() {
        guard let data = try? JSONEncoder().encode(resetBaseline) else { return }
        UserDefaults.standard.set(data, forKey: resetBaselineKey)
    }

    // MARK: 변경

    /// 로그인 성공 후 호출: 토큰을 저장하고 에이전트를 목록에 추가한 뒤 새로고침.
    func addAgent(provider: AgentProvider, tokens: OAuthTokens) async {
        var agent = Agent(provider: provider)
        agent.accountLabel = tokens.accountEmail ?? tokens.plan
        await TokenStore.shared.save(tokens, for: agent.id)
        agents.append(agent)
        persist()
        // 최초 에이전트 추가 시 조용한(provisional) 알림 권한을 요청한다.
        await NotificationManager.shared.requestAuthorizationIfNeeded()
        // 이 refresh는 직전 관측이 없어 자동으로 baseline만 기록한다(처음 추가 시 무알림).
        await refresh(agent)
    }

    func remove(_ agent: Agent) {
        agents.removeAll { $0.id == agent.id }
        snapshots[agent.id] = nil
        // 이 에이전트의 충전형 peak 추정치도 함께 정리(고아 키 방지).
        let prefix = "\(agent.id.uuidString)|"
        let pruned = creditPeaks.filter { !$0.key.hasPrefix(prefix) }
        if pruned.count != creditPeaks.count { creditPeaks = pruned; saveCreditPeaks(pruned) }
        // 리셋 감지 baseline도 함께 정리(고아 키 방지).
        let prunedBaseline = resetBaseline.filter { !$0.key.hasPrefix(prefix) }
        if prunedBaseline.count != resetBaseline.count { resetBaseline = prunedBaseline; saveResetBaseline() }
        persist()
        Task { await TokenStore.shared.delete(for: agent.id) }
        // 이 에이전트에 걸려 있던 예약 리셋 알림도 제거.
        Task { await NotificationManager.shared.removePending(forAgentID: agent.id) }
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
        // 전 에이전트 갱신이 끝난 뒤 예약형 알림을 확정적으로 한 번 재조정한다.
        await rescheduleResetNotifications()
    }

    /// - Parameter manual: 사용자가 직접 [refresh]를 눌렀을 때 true. 버스트 스로틀을 우회하고,
    ///   Codex는 이때 accounts/check에서 현재 plan을 라이브로 읽어 갱신한다(Pro→Free 반영).
    func refresh(_ agent: Agent, manual: Bool = false) async {
        // 이미 조회 중이면 중복 실행 방지.
        guard !loadingIDs.contains(agent.id) else { return }
        // 최근 minFetchSpacing 안에 이미 조회했으면 캐시 유지(버스트 흡수).
        // 단, 수동 새로고침은 방금 조회했더라도 항상 실행한다.
        if !manual, let last = lastFetchAt[agent.id],
           Date().timeIntervalSince(last) < minFetchSpacing { return }
        lastFetchAt[agent.id] = Date()
        loadingIDs.insert(agent.id)
        defer { loadingIDs.remove(agent.id) }
        var snapshot = await ProviderUsage.fetchSnapshot(agent.provider, for: agent.id, manual: manual)
        // 충전형 잔액 창을 게이지로 승격(peak 갱신 포함). RateLimitGate 캐시는 승격 이전 원본을
        // 저장하므로, 캐시로 돌아온 스냅샷도 매번 여기서 승격해야 표시가 일관된다.
        snapshot.windows = promoteCreditWindows(snapshot.windows, agentID: agent.id)

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

        // 플랜 라벨을 얻으면 accountLabel 보강. 이메일을 표시 중이면 건드리지 않고,
        // (a) 비어있거나 (b) 기존에 plan을 표시 중(=이메일이 아님)인데 plan이 바뀐 경우 갱신.
        // → Pro→Free 전환 시 리스트 카드 배지가 stale하게 남지 않는다.
        if let plan = snapshot.planLabel,
           let idx = agents.firstIndex(where: { $0.id == agent.id }) {
            let current = agents[idx].accountLabel ?? ""
            let isEmail = current.contains("@")
            if !isEmail, current != plan {
                agents[idx].accountLabel = plan
                persist()
            }
        }

        // 새 스냅샷이 반영됐으니 다음 리셋 시각의 추가 새로고침을 재예약한다.
        scheduleResetRefresh()

        // 리셋 감지(서프라이즈 즉시 알림 + baseline 갱신) 후 예약형 알림을 재조정한다.
        await detectAndNotifyResets(agentID: agent.id)
        await rescheduleResetNotifications()

        // 서비스 운영 상태도 함께 최신화(스로틀 — 실제 조회는 최소 간격마다 한 번).
        await refreshStatus(for: agent.provider)
    }

    // MARK: 충전형 게이지 승격(peak 추정)

    /// 충전형(balanceRemaining을 가진) 창을 creditGauge로 승격한다. API 총액이 있으면 그 값을,
    /// 없으면 관측 최고 잔액(peak)을 분모로 삼아 소비율을 계산한다. peak는 갱신·영속화한다.
    /// 총액을 못 구하면(첫 관측 0 등) balance 텍스트 그대로 둔다.
    private func promoteCreditWindows(_ windows: [UsageWindow], agentID: UUID) -> [UsageWindow] {
        var peaks = creditPeaks
        var changed = false
        let promoted = windows.map { window -> UsageWindow in
            guard let remaining = window.balanceRemaining else { return window }
            let total: Double
            let estimated: Bool
            if let apiTotal = window.balanceTotal, apiTotal > 0 {
                total = apiTotal
                estimated = false
            } else {
                let key = "\(agentID.uuidString)|\(window.label)"
                let peak = CreditGaugePolicy.newPeak(peaks[key], observed: remaining)
                if peaks[key] != peak { peaks[key] = peak; changed = true }
                total = peak
                estimated = true
            }
            guard let used = CreditGaugePolicy.usedPercent(remaining: remaining, total: total) else {
                return window   // total ≤ 0 → balance 텍스트 fallback
            }
            return window.promotedToCreditGauge(usedPercent: used, estimatedTotal: estimated)
        }
        if changed { creditPeaks = peaks; saveCreditPeaks(peaks) }
        return promoted
    }

    /// 충전형 게이지의 관측 최고 잔액(peak)을 지운다 — 이상 스파이크로 오염된 기준을 사용자가
    /// 수동으로 바로잡을 때 쓴다. 지운 뒤 저장된 스냅샷을 즉시 재승격해, 네트워크 재조회 없이
    /// 현재 잔액을 새 기준(100%)으로 반영한다.
    func resetCreditPeak(agentID: UUID, windowLabel: String) {
        let key = "\(agentID.uuidString)|\(windowLabel)"
        guard creditPeaks[key] != nil else { return }
        creditPeaks[key] = nil
        saveCreditPeaks(creditPeaks)
        if var snap = snapshots[agentID] {
            snap.windows = promoteCreditWindows(snap.windows, agentID: agentID)
            snapshots[agentID] = snap
        }
    }

    // MARK: 서비스 운영 상태 조회

    /// provider의 상태 페이지 JSON을 조회해 serviceStatus를 갱신한다.
    /// - 엔드포인트가 없는 provider는 즉시 반환(항상 "알 수 없음"으로 남는다).
    /// - force가 아니면 statusMinInterval 안에는 재조회하지 않는다.
    /// - 조회/파싱 실패(fetch가 nil)면 직전 상태(last-good)를 그대로 두고 스로틀도 찍지
    ///   않아 다음 주기에 곧바로 재시도한다. 일시적 네트워크·봇차단·타임아웃 한 번이
    ///   정상 배지를 "알 수 없음"으로 덮어쓰거나 오래 고착시키지 않게 하기 위함이다.
    func refreshStatus(for provider: AgentProvider, force: Bool = false) async {
        guard let source = provider.statusSource else { return }
        let now = Date()
        if !force, let last = statusFetchedAt[provider],
           now.timeIntervalSince(last) < statusMinInterval { return }
        // 동시에 여러 에이전트가 같은 provider를 조회할 때 중복 요청을 막는다.
        // 스로틀 시각은 성공 시에만 찍으므로(실패-재시도를 막지 않으려고), 병렬 억제는
        // in-flight 가드가 담당한다. MainActor라 이 검사·삽입은 원자적이다.
        guard !statusInFlight.contains(provider) else { return }
        statusInFlight.insert(provider)
        defer { statusInFlight.remove(provider) }

        guard let health = await ServiceStatusClient.fetch(source) else { return }
        statusFetchedAt[provider] = now
        serviceStatus[provider] = health
    }

    // MARK: 자동 새로고침 (포그라운드 전용)

    /// interval 초마다 전 에이전트를 갱신. interval == 0 이면 즉시 1회만 하고 루프 없음.
    /// interval == AutoRefreshPolicy.sentinel(-1) 이면 Auto 모드: 사용량 변화 속도에
    /// 따라 AutoRefreshPolicy.ladder 안에서 간격을 스스로 조절한다.
    func startAutoRefresh(interval: Int) {
        autoRefreshTask?.cancel()
        let adaptive = (interval == AutoRefreshPolicy.sentinel)
        // Auto 진입/재진입 시 사다리를 기본(1분)으로 되돌린다 — 설정에서 다른 값으로
        // 바꿨다 auto로 돌아오거나 포그라운드로 복귀할 때 항상 1분부터 다시 수렴한다.
        if adaptive { autoLadderIndex = AutoRefreshPolicy.baseIndex }
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
    /// 순수 balance(잔액 텍스트) 창은 usedPercent가 항상 0이라 신호가 없어 제외하지만,
    /// creditGauge(충전형)는 소비율을 가지므로 포함한다(잔액은 느리게 변해 대체로 간격을 늘림).
    private func gaugePercents() -> [String: Double] {
        var out: [String: Double] = [:]
        for (id, snap) in snapshots where snap.error == nil {
            for w in snap.windows where w.isGaugeLike {
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

    // MARK: 리셋 알림(감지형 발화 + 예약형 재조정)

    /// BGAppRefreshTask 핸들러가 호출 — 전 에이전트를 갱신하면 refresh 훅이 감지/예약을 처리한다.
    func performBackgroundRefresh() async {
        await refreshAll()
    }

    /// 백그라운드 스케줄용: 전 에이전트 통틀어 가장 이른 미래 리셋 시각. 없으면 nil.
    func nextResetDate(after now: Date = Date()) -> Date? {
        AutoRefreshPolicy.nextResetDate(in: Array(snapshots.values), after: now)
    }

    /// 설정에서 알림 토글을 바꿨을 때 즉시 예약 알림을 재조정한다(끈 창의 예약은 바로 제거).
    func reapplyNotificationSchedule() async {
        await rescheduleResetNotifications()
    }

    /// 이 에이전트의 새 스냅샷을 직전 baseline과 비교해 "서프라이즈(예정보다 이른) 리셋"을
    /// 즉시 알림한다. 정시 리셋은 예약형이 소유하므로 ResetDetector가 억제한다.
    /// 에러(빈 windows) 스냅샷은 baseline을 오염시키지 않도록 건너뛴다.
    private func detectAndNotifyResets(agentID: UUID) async {
        guard let windows = snapshots[agentID]?.windows, !windows.isEmpty else { return }

        let prefix = "\(agentID.uuidString)|"
        let previous = resetBaseline.filter { $0.key.hasPrefix(prefix) }
        let current = observations(from: windows, agentID: agentID)

        var kindByKey: [String: WindowKind] = [:]
        for w in windows where w.style == .gauge {
            kindByKey["\(agentID.uuidString)|\(w.label)"] = w.kind
        }

        let (events, baseline) = ResetDetector.detect(previous: previous, current: current,
                                                      now: Date()) { kindByKey[$0] ?? .session }

        // baseline 갱신: 이 에이전트의 옛 키를 지우고 새 관측으로 교체(사라진 창 키도 정리).
        for key in previous.keys { resetBaseline[key] = nil }
        for (key, obs) in baseline { resetBaseline[key] = obs }
        saveResetBaseline()

        guard !events.isEmpty, let agent = agents.first(where: { $0.id == agentID }) else { return }
        let loc = L10n(lang: currentLang())
        let fired = events.map { event -> FiredNotification in
            // 예약형과 접두어를 분리한다 — reconcile이 "reset|" pending을 자기 소유로 보고
            // desired에 없으면 지우기 때문에, 접두어를 공유하면 방금 낸 알림이 제거 대상이 된다.
            let id = "\(ResetDetector.firedIDPrefix)\(agentID.uuidString)|\(Int(event.fireTime.timeIntervalSince1970 / 60))"
            return FiredNotification(
                identifier: id,
                title: loc.notifResetTitle(provider: agent.provider.displayName, account: agent.accountLabel),
                body: loc.notifResetBody(session: event.kinds.contains(.session),
                                         weekly: event.kinds.contains(.weekly)),
                agentID: agentID.uuidString)
        }
        await NotificationManager.shared.fire(fired)
    }

    /// 스냅샷 창들을 리셋 감지용 관측 맵으로. 구독 게이지(.gauge)만 대상(충전형·잔액 제외).
    /// 창 주기는 API가 안 주면 종류별 기본값으로 채운다 — 주 신호의 최소 전진 폭 기준이 된다.
    private func observations(from windows: [UsageWindow], agentID: UUID) -> [String: WindowObservation] {
        var out: [String: WindowObservation] = [:]
        for w in windows where w.style == .gauge {
            out["\(agentID.uuidString)|\(w.label)"] = WindowObservation(
                resetsAt: w.resetsAt,
                usedPercent: w.usedPercent,
                windowSeconds: w.windowSeconds ?? w.kind.defaultSeconds)
        }
        return out
    }

    /// 전 에이전트의 미래 리셋을 예약형 알림으로 재조정한다(desired vs pending diff).
    /// refreshAll의 병렬 refresh가 pending 조회를 인터리브하지 않도록 재진입 가드로 하나만 실행한다.
    private func rescheduleResetNotifications() async {
        guard !rescheduleInFlight else { return }
        rescheduleInFlight = true
        defer { rescheduleInFlight = false }

        let now = Date()
        let sessionOn = notifySessionEnabled
        let weeklyOn = notifyWeeklyEnabled
        var all: [ScheduleTarget] = []
        for agent in agents {
            guard let windows = snapshots[agent.id]?.windows else { continue }
            all += ResetSchedulePolicy.targets(agentID: agent.id, windows: windows, now: now,
                                               sessionOn: sessionOn, weeklyOn: weeklyOn)
        }
        let clamped = ResetSchedulePolicy.clampGlobal(all)

        let loc = L10n(lang: currentLang())
        let scheduled = clamped.map { target -> ScheduledNotification in
            let agent = agents.first { $0.id == target.agentID }
            return ScheduledNotification(
                identifier: target.identifier,
                fireTime: target.fireTime,
                title: agent.map { loc.notifResetTitle(provider: $0.provider.displayName, account: $0.accountLabel) }
                    ?? loc.notifDefaultTitle,
                body: loc.notifResetBody(session: target.kinds.contains(.session),
                                         weekly: target.kinds.contains(.weekly)),
                agentID: target.agentID.uuidString)
        }
        await NotificationManager.shared.applyScheduled(scheduled, now: now)
    }

    /// 세션 리셋 알림 on/off(기본 OFF — 5시간마다라 잦음). 키 부재 시 false.
    private var notifySessionEnabled: Bool {
        UserDefaults.standard.bool(forKey: NotificationDefaults.sessionKey)
    }
    /// 주간 리셋 알림 on/off(기본 ON). 키 부재 시 true.
    private var notifyWeeklyEnabled: Bool {
        UserDefaults.standard.object(forKey: NotificationDefaults.weeklyKey) == nil
            ? true : UserDefaults.standard.bool(forKey: NotificationDefaults.weeklyKey)
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

    /// Auto 모드가 오가는 간격 사다리(초): 10초~5분.
    /// - 최소 10초: 급증(surge) 구간에서만 잠깐 내려간다. 적응 브레이크상 소비가
    ///   느려지면 곧 다시 올라가므로, 429가 잦은 Claude라도 10초에 머무는 시간은 짧다
    ///   (그마저도 RateLimitGate가 백오프로 흡수). 리셋 순간 갱신은 리셋 시각 추가
    ///   새로고침이 따로 보장한다.
    /// - 최대 300초(5분): 포그라운드 방치 시 배터리·API 절약. 10분은 방치 체감이
    ///   너무 길어 상한을 5분으로 낮춘다.
    static let ladder = [10, 20, 30, 60, 120, 180, 300]

    /// 시작 인덱스 — 60초("1분 업데이트 기반").
    static let baseIndex = 3

    /// 급증 시 여러 단계를 건너뛰어 곧바로 내려갈 목표 인덱스/임계값(%p).
    /// 사용량이 한 번에 크게 뛰면(예: 2분 간격인데 +14%p) 한 단계씩 줄이는 대신
    /// 30초(중간 급증)나 10초(폭증)로 바로 급강하한다.
    static let quickIndex = 2            // 30초
    static let surgeToFast: Double = 5   // ≥5%p → 30초로 건너뛰기
    static let surgeToFastest: Double = 10  // ≥10%p → 10초로 급강하

    /// 서버 시계 오차에 대비해 리셋 시각 뒤에 두는 여유(초).
    static let resetSlack: TimeInterval = 1

    /// 변화폭(maxDelta, %p)에 따른 다음 사다리 인덱스(작을수록 짧은 간격).
    /// ≥10은 10초로 급강하, ≥5는 30초로 건너뛰기(단 이미 더 빠르면 유지),
    /// ≥4는 두 단계·≥2는 한 단계 단축, ≤1은 한 단계 연장, (1,2) 구간은 유지(히스테리시스).
    /// nil(겹치는 창 없음·전부 에러)은 현재 유지. 결과는 사다리 범위로 클램프.
    static func nextLadderIndex(from index: Int, maxDelta: Double?) -> Int {
        guard let delta = maxDelta else { return index }
        var next = index
        if delta >= surgeToFastest {
            next = 0                       // 폭증 → 곧바로 최소 간격(10초)
        } else if delta >= surgeToFast {
            next = min(next, quickIndex)   // 급증 → 30초로 건너뛰되, 이미 더 빠르면 유지
        } else if delta >= 4 {
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

// MARK: - 충전형 게이지 정책(순수 로직)

/// 충전형(선불 크레딧) 잔액을 게이지 사용률로 환산하는 순수 정책 — AgentStore와 단위 테스트가 공유한다.
enum CreditGaugePolicy {
    /// 남은 잔액과 총액으로 "소비율(%)"을 낸다. total>0이 아니면 nil(→ balance 텍스트 fallback).
    /// 예) remaining=487.3, total=500 → 2.54% used. 초과지출(remaining<0)은 100%로 clamp.
    static func usedPercent(remaining: Double, total: Double) -> Double? {
        guard total > 0 else { return nil }
        let used = (1 - remaining / total) * 100
        return min(100, max(0, used))
    }

    /// 관측된 잔액으로 갱신한 최고 잔액(peak). 추가 충전 시 커지며, 그 순간 게이지가 100%로 리셋된다.
    static func newPeak(_ stored: Double?, observed: Double) -> Double {
        max(stored ?? 0, observed)
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
