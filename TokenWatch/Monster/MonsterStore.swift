//
//  MonsterStore.swift
//  TokenWatch
//
//  몬스터 사냥(V2) 상태 머신. 게이지 창을 보고 출현을 요청·추첨하고, 타격·처치를 처리하고,
//  서버 판정 결과·리더보드·내 순위를 들고 있다.
//
//  - 주인(owner): 몬스터 동의(약관 v2)를 한 로그인 계정이면 그 uid(서버 판정, 순위 반영),
//    아니면 게스트(기기 추첨, 비순위). 화면에는 지금 주인의 몬스터만 그린다.
//  - 출현 요청은 포그라운드 새로고침에서만 한다(백그라운드 갱신은 만료 처리만). 크리터 표시를 끄면 멈춘다.
//  - 데모 중에는 서버·파일 저장을 하지 않는다. 표본 100% 게이지와 Codex 주간 게이지(고블린)에 메모리 전용 표본 몬스터를
//    그린다. 데모에서 잡은 몬스터는 게스트 기록·점수에 들어가지 않는다.
//  - 서버로 보내는 것은 계약 §15의 값뿐이다(provider·창 label·주기·세션 창 여부·리셋 버킷·에이전트 키·플랫폼·앱 버전).
//    사용률 수치·AI 서비스 계정 정보는 보내지 않는다.
//

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class MonsterStore {
    /// 몬스터 기능 동의가 필요한 약관 버전(계약 §15-2).
    static let termsVersion = 2
    /// 설정 갱신 간격.
    static let configRefreshInterval: TimeInterval = 3600
    /// 리더보드·내 순위 캐시.
    static let guildCacheInterval: TimeInterval = 300
    /// 처치한 뒤 엔젤링 유령을 남겨 두는 시간(1시간, 사용자 확정 2026-10-26). 확률 출현 유령은 이 시간이 지나면 사라지고,
    /// 완료 출현 유령은 리셋까지 남되 이 시간이 지나면 새 확률 몬스터에게 바를 내준다.
    static let ghostHoldMs: Int64 = 3_600_000

    /// 의존성. 테스트는 시계·포그라운드·저장소를 바꿔 끼운다.
    struct Environment {
        var isDemo: () -> Bool
        var crittersEnabled: () -> Bool
        var isForeground: () -> Bool
        var nowMs: () -> Int64
        var appVersion: String
        /// 전 에이전트의 현재 창(확률 출현 후보를 모으는 데 쓴다).
        var snapshots: () -> [(agent: Agent, windows: [UsageWindow])]
    }

    enum HitResult: Equatable {
        case ignored
        case damaged(remaining: Int)
        case defeated
    }

    private(set) var config: MonsterConfig
    private(set) var ledger: MonsterLedgerState
    /// 서버가 돌려준 내 통계(계정일 때).
    private(set) var stats: MonsterStatsDTO?
    private(set) var rank: MyRankDTO?
    /// 탭별 상위 100. 이번 주 목록은 `leaderboardWeekID` 주의 것이다.
    private(set) var leaderboards: [LeaderboardScope: [LeaderboardEntry]] = [:]
    private(set) var leaderboardLoadedAt: [LeaderboardScope: Date] = [:]
    private(set) var leaderboardFailed: Set<LeaderboardScope> = []
    @ObservationIgnored private var leaderboardWeekID: String?
    /// 마지막 타격 시각(검 효과 표시용).
    private(set) var lastHitAt: [String: Date] = [:]
    /// 서버가 동의를 요구했다(`consent_required`).
    private(set) var consentRequested = false
    /// 프로필 도감: 지금 계정의 종별 처치 수(서버 기록 + 합친 게스트 이력). nil이면 아직 못 읽었다.
    private(set) var bestiaryKills: [String: Int]?
    private var bestiaryLoadFailed = false
    @ObservationIgnored private var bestiaryOwner: String?

    @ObservationIgnored private let account: AccountStore
    @ObservationIgnored private let api: MonsterAPIClient?
    @ObservationIgnored private let env: Environment
    @ObservationIgnored private let storage: MonsterLedgerStorage
    @ObservationIgnored private let sessionStorage: DeviceSessionLedgerStorage
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var inFlight: Set<String> = []
    /// 키별 다음 요청 가능 시각(ms). 확정 거절은 이번 실행 동안 다시 묻지 않는다(Int64.max).
    @ObservationIgnored private var retryAfter: [String: Int64] = [:]
    @ObservationIgnored private var lastHitMs: [String: Int64] = [:]
    @ObservationIgnored private var rankLoadedAt: Date?
    /// 데모 표본 몬스터의 남은 HP와 처치 시각(메모리 전용 — 처치 시각이 있어야 사망 애니메이션이 나온다).
    @ObservationIgnored private var demoHP: [String: Int] = [:]
    @ObservationIgnored private var demoDefeatedAt: [String: Int64] = [:]
    /// 데모 확률 출현 표본을 처음 그린 시각(행진 출발점).
    @ObservationIgnored private var demoSpawnedAt: [String: Int64] = [:]
    private var demoTick = 0

    private static let configCacheKey = "tokenwatch.monster.config.v1"
    private static let configFetchedAtKey = "tokenwatch.monster.configFetchedAt"

    init(account: AccountStore, api: MonsterAPIClient?, environment: Environment,
         storage: MonsterLedgerStorage? = nil,
         sessionStorage: DeviceSessionLedgerStorage? = nil,
         defaults: UserDefaults = .standard) {
        let storage = storage ?? MonsterLedgerFile()
        self.account = account
        self.api = api
        self.env = environment
        self.storage = storage
        self.sessionStorage = sessionStorage ?? DeviceSessionLedgerKeychain()
        self.defaults = defaults
        var loaded = storage.load() ?? MonsterLedgerState()
        loaded.prune()
        ledger = loaded
        config = defaults.data(forKey: Self.configCacheKey).flatMap(MonsterConfigDecoder.decodePayload)
            ?? .bundledDefault
    }

    /// 앱에서 쓰는 실제 구성.
    static func live(account: AccountStore, agents: AgentStore) -> MonsterStore {
        let projectID = PlayerProfileClient.bundledProjectID()
        let api = projectID.map { id in
            MonsterAPIClient(projectID: id, apiKey: MonsterAPIClient.bundledAPIKey(),
                             token: { [weak account] force in await account?.idToken(forceRefresh: force) })
        }
        let env = Environment(
            isDemo: { [weak agents] in agents?.isDemo ?? false },
            crittersEnabled: { UserDefaults.standard.object(forKey: "tokenwatch.gaugeCritter") as? Bool ?? true },
            isForeground: { UIApplicationStateProbe.isActive },
            nowMs: { MonsterSessionKey.epochMs(Date()) },
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
            snapshots: { [weak agents] in
                guard let agents else { return [] }
                return agents.agents.compactMap { a in agents.snapshots[a.id].map { (a, $0.windows) } }
            })
        return MonsterStore(account: account, api: api, environment: env)
    }

    /// 미리보기용 — 서버·파일·Keychain을 쓰지 않는다.
    static func preview(account: AccountStore, agents: AgentStore) -> MonsterStore {
        let env = Environment(
            isDemo: { [weak agents] in agents?.isDemo ?? false }, crittersEnabled: { true }, isForeground: { false },
            nowMs: { MonsterSessionKey.epochMs(Date()) }, appVersion: "0", snapshots: { [] })
        return MonsterStore(account: account, api: nil, environment: env, storage: MonsterLedgerMemory(),
                            sessionStorage: DeviceSessionLedgerMemory(),
                            defaults: UserDefaults(suiteName: "MonsterStore.preview") ?? .standard)
    }

    // MARK: 주인·동의

    /// 지금 몬스터를 쌓는 계정(동의한 로그인 계정). nil이면 게스트.
    var activeOwner: String? {
        guard api != nil, let uid = account.uid, let p = account.profile,
              p.termsAcceptedVersion >= Self.termsVersion else { return nil }
        return uid
    }

    /// 데모 중이면 순위·도감·PLAYER 화면이 표본 모험가(`DemoAdventure`)를 보여 준다.
    var isDemo: Bool { env.isDemo() }

    /// 로그인했고 프로필도 있지만 몬스터 동의 전이다(동의 화면을 띄울 대상).
    var needsConsent: Bool {
        guard api != nil, !env.isDemo(), let p = account.profile else { return false }
        return p.termsAcceptedVersion < Self.termsVersion
    }

    /// 동의를 서버에 기록한다. 성공하면 게스트 기록을 한 번 합친다.
    func acceptConsent() async -> Bool {
        guard let api, !env.isDemo(), account.uid != nil else { return false }
        switch await api.acceptTerms(version: Self.termsVersion) {
        case .success(let version):
            account.markTermsAccepted(version: version)
            consentRequested = false
            retryAfter.removeAll()
            await mergeGuestHistoryIfNeeded()
            return true
        case .failure:
            return false
        }
    }

    /// 게스트 처치 기록을 계정에 비순위 이력으로 한 번 합친다(§15-7).
    func mergeGuestHistoryIfNeeded() async {
        guard let api, let owner = activeOwner, !ledger.mergedUIDs.contains(owner) else { return }
        guard !ledger.guest.kills.isEmpty else {
            ledger.mergedUIDs.append(owner)
            save()
            return
        }
        switch await api.mergeGuestHistory(ledger.guest) {
        case .success, .failure(.server):
            // 합쳤거나(이미 합친 계정은 merged=false), 서버가 받지 않는 이력이면 다시 보내지 않는다.
            ledger.mergedUIDs.append(owner)
            save()
        case .failure:
            break   // 오프라인 등 — 다음 관측 때 다시
        }
    }

    // MARK: 관측(새로고침 훅)

    /// 에이전트 하나가 새로고침될 때마다 부른다(AgentStore 훅). 포그라운드에서만 출현을 요청한다.
    func observe(agent: Agent, windows: [UsageWindow]) async {
        guard !env.isDemo() else { return }
        let now = env.nowMs()
        expireFinished(now: now)
        guard env.crittersEnabled(), env.isForeground() else {
            save()
            return
        }
        await refreshConfigIfNeeded()
        let owner = activeOwner
        if let owner, !ledger.mergedUIDs.contains(owner) { await mergeGuestHistoryIfNeeded() }
        let date = Date(timeIntervalSince1970: Double(now) / 1000)
        for window in windows where MonsterEligibility.isCompleted(window, now: date) {
            await handleCompletion(agent: agent, window: window, owner: owner, now: now)
        }
        await handleRandom(owner: owner, now: now)
        await retryPendingDefeats(owner: owner)
        save()
    }

    private func handleCompletion(agent: Agent, window: UsageWindow, owner: String?, now: Int64) async {
        guard config.completionEnabled, let resetsAt = window.resetsAt else { return }
        let keyLabel = MonsterSessionKey.keyLabel(provider: agent.provider, label: window.label)
        let resetsAtMs = MonsterSessionKey.keyResetsAtMs(provider: agent.provider, resetsAt: resetsAt)
        let bucket = MonsterSessionKey.resetBucketMs(resetsAtMs)
        let key = MonsterSessionKey.completionKey(uid: owner ?? "guest", provider: agent.provider, resetBucketMs: bucket)
        if let index = ledger.encounters.firstIndex(where: { $0.key == key }) {
            anchorIfNeeded(index, agentID: agent.id, label: window.label)
            return
        }
        guard canRequest(key, now: now) else { return }
        if let owner, let api {
            let ledgerKey = MonsterSessionKey.completionLedgerKey(provider: agent.provider, resetBucketMs: bucket)
            var session = sessionStorage.load()
            guard !session.blocks(key: ledgerKey, uid: owner) else { return }
            inFlight.insert(key)
            let result = await api.spawnCompletion(
                provider: agent.provider.rawValue, windowLabel: keyLabel,
                periodSec: MonsterSessionKey.periodSec(provider: agent.provider, label: window.label,
                                                       windowSeconds: window.windowSeconds, kind: window.kind),
                session: window.kind == .session, resetBucketMs: bucket, resetsAtMs: MonsterSessionKey.epochMs(resetsAt))
            inFlight.remove(key)
            if case .success(.encounter) = result {
                session.record(key: ledgerKey, uid: owner, nowMs: now)
                session.purge(nowMs: now)
                sessionStorage.save(session)
            }
            apply(result, key: key, owner: owner, anchor: (agent.id, window.label), now: now)
        } else {
            let decision = GuestSpawnPolicy.decide(
                isCompletion: true, key: key, salt: ledger.deviceSalt, config: config, progress: ledger.guest,
                aliveRandom: 0, nowMs: now, appVersion: env.appVersion)
            guard case .spawn(let entry) = decision else {
                retryAfter[key] = now + 600_000
                return
            }
            addGuestEncounter(key: key, source: .completion, provider: agent.provider.rawValue, windowLabel: keyLabel,
                              resetBucketMs: bucket, drawAtMs: nil,
                              entry: MonsterDraw.forWindow(entry, session: window.kind == .session, config: config,
                                                           appVersion: env.appVersion),
                              now: now,
                              expiresAtMs: MonsterSessionKey.epochMs(resetsAt), anchor: (agent.id, window.label))
        }
    }

    /// 확률 출현(§15-11): 에이전트(연결한 AI 계정)마다 20~40분 간격으로 한 번씩 추첨한다. 일정은 원장에
    /// 에이전트별로 계정과 무관하게 두고(계정을 바꿔도 추첨이 늘지 않는다), 로그인 계정은 서버가 정한 다음 시각을 따른다.
    /// 처음 보인 에이전트는 바로 뽑지 않고 일정만 정한다. 같은 AI 계정을 여러 번 추가했으면 처음 것만 뽑는다.
    private func handleRandom(owner: String?, now: Int64) async {
        guard config.random.enabled else { return }
        let date = Date(timeIntervalSince1970: Double(now) / 1000)
        var drawn = 0
        var accounts: Set<String> = []
        for (agent, windows) in env.snapshots() {
            guard drawn < config.random.maxAgentsPerUser else { break }
            guard accounts.insert(MonsterEligibility.accountSignature(
                provider: agent.provider, windows: windows, now: date)).inserted else { continue }
            // 후보: 이 에이전트의 대상 창, label 단위로 하나씩(최대 20). 몬스터가 살아 있는 바는 빼고,
            // 처치 1시간 안의 유령이 있는 바는 빈 바가 하나도 없을 때만 쓴다(그때 새 몬스터가 유령을 치운다).
            var anchors: [String: String] = [:]
            var free: [MonsterAPIClient.RandomCandidate] = []
            var haunted: [MonsterAPIClient.RandomCandidate] = []
            for window in windows where MonsterEligibility.isRandomCandidate(
                window, minUsedPercent: config.random.minUsedPercent, now: date) {
                let keyLabel = MonsterSessionKey.keyLabel(provider: agent.provider, label: window.label)
                guard anchors[keyLabel] == nil, anchors.count < 20 else { continue }
                let shown = encounters(agentID: agent.id, provider: agent.provider, window: window)
                guard !shown.contains(where: \.isAlive) else { continue }
                anchors[keyLabel] = window.label
                let ghost = shown.contains { e in
                    e.state == .defeated && e.defeatedAtMs.map { now - $0 < Self.ghostHoldMs } ?? false
                }
                let candidate: MonsterAPIClient.RandomCandidate = (agent.provider.rawValue, keyLabel, window.kind == .session)
                if ghost { haunted.append(candidate) } else { free.append(candidate) }
            }
            let candidates = free.isEmpty ? haunted : free
            guard !candidates.isEmpty else { continue }   // 대상 창이 없으면 일정을 그대로 둔다
            drawn += 1
            await drawRandom(agent: agent, candidates: candidates, anchors: anchors, owner: owner, now: now)
        }
    }

    private func drawRandom(agent: Agent, candidates: [MonsterAPIClient.RandomCandidate],
                            anchors: [String: String], owner: String?, now: Int64) async {
        let token = MonsterSessionKey.agentToken(agent.id)
        let retryKey = "rand|\(token)"
        let due = ledger.nextDraw(agent: token)
        guard due.map({ $0 <= now }) ?? true, canRequest(retryKey, now: now) else { return }
        if let owner, let api {
            inFlight.insert(retryKey)
            let result = await api.spawnRandom(
                agentKey: MonsterSessionKey.agentKey(uid: owner, agentToken: token), candidates: candidates)
            inFlight.remove(retryKey)
            switch result {
            case .success(let draw):
                // 기기 시계가 서버보다 빠르면 예정 시각이 이미 지난 것으로 보일 수 있다 — 1분 간격으로만 다시 묻는다.
                let next = draw.nextDrawAtMs ?? now + MonsterDraw.drawIntervalMs(config: config, roll: 0)
                ledger.setNextDraw(max(next, now + 60_000), agent: token, nowMs: now)
                if let dto = draw.encounter {
                    apply(.success(.encounter(dto)), key: dto.key, owner: owner,
                          anchor: anchors[dto.windowLabel].map { (agent.id, $0) }, now: now)
                }
            case .failure(let error):
                apply(.failure(error), key: retryKey, owner: owner, anchor: nil, now: now)
            }
            return
        }
        let salt = ledger.deviceSalt
        guard let due else {
            let first = MonsterDraw.drawIntervalMs(config: config, roll: MonsterDraw.unitRoll("\(salt)|\(token)|first"))
            ledger.setNextDraw(now + first, agent: token, nowMs: now)
            return
        }
        let key = MonsterSessionKey.randomKey(uid: "guest", agentKey: token, drawAtMs: due)
        let interval = MonsterDraw.drawIntervalMs(config: config, roll: MonsterDraw.unitRoll("\(salt)|\(key)|next"))
        ledger.setNextDraw(now + interval, agent: token, nowMs: now)
        guard !ledger.encounters.contains(where: { $0.key == key }) else { return }
        let aliveRandom = ledger.encounters.filter { $0.ownerUID == nil && $0.source == .random && $0.isAlive }.count
        let decision = GuestSpawnPolicy.decide(
            isCompletion: false, key: key, salt: salt, config: config, progress: ledger.guest,
            aliveRandom: aliveRandom, nowMs: now, appVersion: env.appVersion)
        guard case .spawn(let entry) = decision else { return }
        let pick = min(candidates.count - 1,
                       Int(MonsterDraw.unitRoll("\(salt)|\(key)|cand") * Double(candidates.count)))
        let chosen = candidates[pick]
        addGuestEncounter(key: key, source: .random, provider: chosen.provider, windowLabel: chosen.windowLabel,
                          resetBucketMs: nil, drawAtMs: due,
                          entry: MonsterDraw.forWindow(entry, session: chosen.session, config: config,
                                                       appVersion: env.appVersion),
                          now: now,
                          expiresAtMs: now + Int64(config.random.lifetimeMinutes) * 60_000,
                          anchor: anchors[chosen.windowLabel].map { (agent.id, $0) })
    }

    private func addGuestEncounter(key: String, source: MonsterEncounter.Source, provider: String, windowLabel: String,
                                   resetBucketMs: Int64?, drawAtMs: Int64?, entry: MonsterCatalogEntry, now: Int64,
                                   expiresAtMs: Int64, anchor: (UUID, String)?) {
        let encounter = MonsterEncounter(
            key: key, ownerUID: nil, source: source, provider: provider, windowLabel: windowLabel,
            resetBucketMs: resetBucketMs, drawAtMs: drawAtMs, monsterID: entry.id, maxHP: entry.hp, hp: entry.hp,
            state: .alive, spawnedAtMs: now, expiresAtMs: expiresAtMs, agentID: anchor?.0, displayLabel: anchor?.1,
            position: MonsterDraw.position(key: key))
        ledger.encounters.append(encounter)
        dismissGhosts(under: encounter, now: now)
        GuestSpawnPolicy.recordSpawn(&ledger.guest, nowMs: now)
        AnalyticsService.shared.log(.monsterSpawn(monsterID: entry.id, source: source))
    }

    /// 새 몬스터가 앉은 바의 유령을 치운다 — 한 바에는 몬스터든 유령이든 하나만 보인다.
    private func dismissGhosts(under encounter: MonsterEncounter, now: Int64) {
        for i in ledger.encounters.indices {
            let e = ledger.encounters[i]
            guard e.key != encounter.key, e.ownerUID == encounter.ownerUID, e.state == .defeated, e.dismissedAtMs == nil,
                  e.provider == encounter.provider, e.windowLabel == encounter.windowLabel else { continue }
            if let a = e.agentID, let b = encounter.agentID, a != b { continue }
            ledger.encounters[i].dismissedAtMs = now
        }
    }

    /// 서버 출현 응답 반영.
    private func apply(_ result: Result<MonsterAPIClient.SpawnResult, MonsterAPIClient.CallError>, key: String,
                       owner: String, anchor: (UUID, String)?, now: Int64) {
        switch result {
        case .success(.encounter(let dto)):
            guard !ledger.encounters.contains(where: { $0.key == dto.key }) else { return }
            let state: MonsterEncounter.State = dto.state == "alive" ? .alive : (dto.state == "defeated" ? .defeated : .expired)
            let encounter = MonsterEncounter(
                key: dto.key, ownerUID: owner, source: MonsterEncounter.Source(rawValue: dto.source) ?? .completion,
                provider: dto.provider, windowLabel: dto.windowLabel, resetBucketMs: dto.resetBucketMs,
                drawAtMs: dto.drawAtMs, monsterID: dto.monsterID, maxHP: dto.maxHP,
                hp: state == .alive ? dto.maxHP : 0, state: state, spawnedAtMs: dto.spawnedAtMs,
                expiresAtMs: dto.expiresAtMs, defeatedAtMs: dto.defeatedAtMs, awardedScore: dto.awardedScore,
                agentID: anchor?.0, displayLabel: anchor?.1, position: MonsterDraw.position(key: dto.key))
            ledger.encounters.append(encounter)
            if state == .alive {
                dismissGhosts(under: encounter, now: now)
                AnalyticsService.shared.log(.monsterSpawn(monsterID: dto.monsterID, source: encounter.source))
            }
        case .success(.none):
            retryAfter[key] = now + 600_000
        case .failure(.server(let code)):
            switch code {
            case "consent_required":
                consentRequested = true
                retryAfter[key] = now + 600_000
            case "daily_cap", "agent_limit":
                retryAfter[key] = now + 3_600_000
            case "invalid_reset", "too_frequent", "invalid_argument", "suspended", "profile_required":
                retryAfter[key] = .max
            default:
                retryAfter[key] = now + 300_000
            }
        case .failure:
            retryAfter[key] = now + 120_000
        }
    }

    private func canRequest(_ key: String, now: Int64) -> Bool {
        !inFlight.contains(key) && (retryAfter[key] ?? 0) <= now
    }

    /// 다른 기기에서 받은 몬스터처럼 붙일 창을 모르면 처음 본 창에 붙인다(이미 붙어 있으면 그대로 — 같은 리셋을
    /// 공유하는 창이 여러 개여도 몬스터가 창 사이를 옮겨 다니지 않게).
    private func anchorIfNeeded(_ index: Int, agentID: UUID, label: String) {
        guard ledger.encounters[index].agentID == nil else { return }
        ledger.encounters[index].agentID = agentID
        ledger.encounters[index].displayLabel = label
    }

    private func expireFinished(now: Int64) {
        for i in ledger.encounters.indices where ledger.encounters[i].isAlive && ledger.encounters[i].expiresAtMs <= now {
            ledger.encounters[i].state = .expired
            ledger.encounters[i].hp = 0
        }
        ledger.prune()
    }

    // MARK: 타격·처치

    /// 몬스터가 있는 게이지 줄을 한 번 눌렀다(HP 1 감소). 디바운스 간격 안의 연타는 무시한다.
    @discardableResult
    func hit(key: String) -> HitResult {
        if env.isDemo() { return hitDemo(key: key) }
        let now = env.nowMs()
        guard let index = ledger.encounters.firstIndex(where: { $0.key == key }),
              ledger.encounters[index].isAlive, ledger.encounters[index].expiresAtMs > now else { return .ignored }
        if let last = lastHitMs[key], now - last < Int64(config.tapDebounceMs) { return .ignored }
        lastHitMs[key] = now
        lastHitAt[key] = Date()
        ledger.encounters[index].hp -= 1
        let encounter = ledger.encounters[index]
        guard encounter.hp <= 0 else {
            save()
            return .damaged(remaining: encounter.hp)
        }
        ledger.encounters[index].hp = 0
        ledger.encounters[index].state = .defeated
        ledger.encounters[index].defeatedAtMs = now
        let entry = config.entry(encounter.monsterID)
        let score = entry?.score ?? 0
        if encounter.ownerUID == nil {
            ledger.encounters[index].awardedScore = score
            GuestSpawnPolicy.recordKill(&ledger.guest, entry: entry, monsterID: encounter.monsterID, nowMs: now)
        } else {
            ledger.encounters[index].pendingDefeat = true
            Task { await self.sendDefeat(key: key) }
        }
        AnalyticsService.shared.log(.monsterKill(monsterID: encounter.monsterID, hp: encounter.maxHP, score: score,
                                                 source: encounter.source))
        save()
        return .defeated
    }

    /// 처치를 서버에 확정한다. 오프라인이면 남겨 두고 다음 포그라운드 새로고침에 다시 보낸다.
    func sendDefeat(key: String) async {
        guard let api, !inFlight.contains(key),
              let index = ledger.encounters.firstIndex(where: { $0.key == key }),
              ledger.encounters[index].pendingDefeat, let defeatedAt = ledger.encounters[index].defeatedAtMs else { return }
        inFlight.insert(key)
        let result = await api.defeat(key: key, defeatedAtMs: defeatedAt)
        inFlight.remove(key)
        guard let i = ledger.encounters.firstIndex(where: { $0.key == key }) else { return }
        switch result {
        case .success(let (dto, newStats)):
            ledger.encounters[i].pendingDefeat = false
            if let dto {
                if dto.state == "expired" {
                    ledger.encounters[i].state = .expired
                    ledger.encounters[i].awardedScore = 0
                } else {
                    ledger.encounters[i].awardedScore = dto.awardedScore
                }
            }
            if let newStats { stats = newStats }
        case .failure(.server):
            // 서버가 받지 않은 처치(만료·없는 키 등)는 다시 보내지 않는다.
            ledger.encounters[i].pendingDefeat = false
        case .failure:
            break
        }
        save()
    }

    private func retryPendingDefeats(owner: String?) async {
        guard let owner else { return }
        for key in ledger.encounters.filter({ $0.ownerUID == owner && $0.pendingDefeat }).map(\.key) {
            await sendDefeat(key: key)
        }
    }

    // MARK: 화면

    /// 이 창에 그릴 몬스터(살아 있는 것, 처치돼 엔젤링이 뜬 것). 다른 주인(게스트↔계정)의 것은 그리지 않는다.
    func encounters(agentID: UUID, provider: AgentProvider, window: UsageWindow) -> [MonsterEncounter] {
        guard env.crittersEnabled() else { return [] }
        if env.isDemo() { return demoEncounters(agentID: agentID, provider: provider, window: window) }
        let now = env.nowMs()
        let owner = activeOwner
        let keyLabel = MonsterSessionKey.keyLabel(provider: provider, label: window.label)
        return ledger.encounters.filter { e in
            guard e.ownerUID == owner, e.state != .expired, e.dismissedAtMs == nil else { return false }
            // 확률 출현 유령은 처치 뒤 1시간(살아 있던 시간과 무관), 나머지는 만료(완료 출현은 리셋)까지.
            if e.source == .random, e.state == .defeated {
                guard let at = e.defeatedAtMs, now - at < Self.ghostHoldMs else { return false }
            } else if e.expiresAtMs <= now {
                return false
            }
            if let anchored = e.agentID { return anchored == agentID && e.displayLabel == window.label }
            return e.provider == provider.rawValue && e.windowLabel == keyLabel
        }
    }

    /// 지금 주인의 처치 합계(게스트는 기기 기록, 계정은 서버 통계).
    var guestKillCount: Int { ledger.guest.kills.values.reduce(0, +) }

    // MARK: 데모

    /// 데모의 확률 출현 표본: Codex 주간 게이지(94%)의 고블린(HP 3). 100% 게이지의 슬라임 옆에서 여러 번 쳐야 잡히는
    /// 몬스터와 나타난 자리에서 출발하는 행진을 보여 준다. 값은 Android와 같다.
    private static let demoRandom = (provider: AgentProvider.codex, windowLabel: "Current week",
                                     monsterID: "goblin", position: 0.35)

    /// 데모 표본 몬스터(메모리 전용 — 저장·서버 호출·점수 없음). 100% 게이지에는 창마다 결정적 종 하나(완료 출현),
    /// `demoRandom` 게이지에는 고블린(확률 출현)이 나온다.
    private func demoEncounters(agentID: UUID, provider: AgentProvider, window: UsageWindow) -> [MonsterEncounter] {
        let now = Date()
        _ = demoTick   // 타격 시 다시 그리게 관찰 대상에 둔다
        var shown: [MonsterEncounter] = []
        if MonsterEligibility.isCompleted(window, now: now) {
            shown.append(demoEncounter(key: "demo|\(agentID.uuidString)|\(window.label)", source: .completion,
                                       spawnedAtMs: 0, position: 0.5, agentID: agentID, window: window))
        }
        if provider == Self.demoRandom.provider, window.label == Self.demoRandom.windowLabel,
           MonsterEligibility.isTarget(window, now: now) {
            let key = "demo|rand|\(agentID.uuidString)|\(window.label)"
            // 처음 그린 시각을 출현 시각으로 둔다 — 정해 둔 자리에서 행진을 시작한다.
            let spawned = demoSpawnedAt[key] ?? env.nowMs()
            demoSpawnedAt[key] = spawned
            shown.append(demoEncounter(key: key, source: .random, spawnedAtMs: spawned,
                                       position: Self.demoRandom.position, agentID: agentID, window: window))
        }
        return shown
    }

    private func demoEncounter(key: String, source: MonsterEncounter.Source, spawnedAtMs: Int64, position: Double,
                               agentID: UUID, window: UsageWindow) -> MonsterEncounter {
        let entry = demoEntry(key: key)
        let hp = demoHP[key] ?? entry.hp
        return MonsterEncounter(
            key: key, ownerUID: "demo", source: source, provider: "", windowLabel: window.label,
            resetBucketMs: nil, drawAtMs: nil, monsterID: entry.id, maxHP: entry.hp, hp: max(0, hp),
            state: hp > 0 ? .alive : .defeated, spawnedAtMs: spawnedAtMs, expiresAtMs: .max,
            defeatedAtMs: demoDefeatedAt[key], agentID: agentID, displayLabel: window.label, position: position)
    }

    /// 데모 몬스터의 종. 확률 출현 표본은 고블린, 100% 게이지는 키로 정한 결정적 종이다.
    private func demoEntry(key: String) -> MonsterCatalogEntry {
        let config = MonsterConfig.bundledDefault
        if key.hasPrefix("demo|rand|"), let entry = config.entry(Self.demoRandom.monsterID) { return entry }
        return MonsterDraw.pick(config: config, appVersion: env.appVersion, commonOnly: false,
                                roll: MonsterDraw.unitRoll(key))
    }

    private func hitDemo(key: String) -> HitResult {
        guard key.hasPrefix("demo|") else { return .ignored }
        let entry = demoEntry(key: key)
        let current = demoHP[key] ?? entry.hp
        guard current > 0 else { return .ignored }
        let now = env.nowMs()
        if let last = lastHitMs[key], now - last < Int64(config.tapDebounceMs) { return .ignored }
        lastHitMs[key] = now
        lastHitAt[key] = Date()
        demoHP[key] = current - 1
        if current - 1 <= 0 { demoDefeatedAt[key] = now }
        demoTick += 1
        return current - 1 > 0 ? .damaged(remaining: current - 1) : .defeated
    }

    // MARK: 길드

    /// 그 탭의 상위 100과 내 순위를 읽는다. 5분 안에 읽었으면 건너뛴다(force면 바로).
    /// 이번 주 탭은 주가 바뀌었으면(월요일 0시 KST) 시간과 상관없이 새로 읽는다.
    func refreshGuild(_ scope: LeaderboardScope, force: Bool = false) async {
        guard let api, !env.isDemo() else { return }
        let weekID = MonsterDraw.kstWeekId(nowMs: env.nowMs())
        let stale = scope == .week && leaderboardWeekID != weekID
        if force || stale || leaderboardLoadedAt[scope].map({ Date().timeIntervalSince($0) > Self.guildCacheInterval }) ?? true {
            if let list = await api.leaderboardTop(scope, weekID: weekID) {
                leaderboards[scope] = list
                leaderboardLoadedAt[scope] = Date()
                leaderboardFailed.remove(scope)
                if scope == .week { leaderboardWeekID = weekID }
            } else {
                leaderboardFailed.insert(scope)
            }
        }
        guard activeOwner != nil,
              force || stale || rankLoadedAt.map({ Date().timeIntervalSince($0) > Self.guildCacheInterval }) ?? true
        else { return }
        if case .success(let r) = await api.myRank() {
            rank = r
            stats = r.stats
            rankLoadedAt = Date()
        }
    }

    /// 그 탭의 리더보드(받아 온 상위 10).
    func leaderboard(_ scope: LeaderboardScope) -> [LeaderboardEntry] {
        leaderboards[scope] ?? []
    }

    // MARK: 도감

    /// 프로필 도감을 열 때 계정의 종별 처치 수를 읽는다(문서 GET 한 번). 읽는 동안은 지난 값을 보여 준다.
    func refreshBestiary() async {
        guard let api, !env.isDemo(), let uid = account.uid else { return }
        if bestiaryOwner != uid {
            bestiaryOwner = uid
            bestiaryKills = nil
        }
        bestiaryLoadFailed = false
        let kills = await api.myKills(uid: uid)
        guard account.uid == uid else { return }
        if let kills { bestiaryKills = kills } else if bestiaryKills == nil { bestiaryLoadFailed = true }
    }

    /// 도감 줄(지금 설정 기준). 처치 수를 아직 못 읽었거나 지난 값이 다른 계정 것이면 nil
    /// (계정을 바꾼 직후 다시 읽기 전 첫 프레임에도 다른 계정 기록을 보이지 않게).
    var bestiaryRows: [BestiaryRow]? {
        if env.isDemo() { return MonsterBestiary.rows(config: config, kills: DemoAdventure.kills, appVersion: env.appVersion) }
        guard bestiaryOwner == account.uid else { return nil }
        return bestiaryKills.map { MonsterBestiary.rows(config: config, kills: $0, appVersion: env.appVersion) }
    }

    /// 지금 계정의 처치 수를 처음 읽다가 실패했다.
    var bestiaryFailed: Bool { !env.isDemo() && bestiaryOwner == account.uid && bestiaryLoadFailed }

    // MARK: 계정 삭제·설정·저장

    /// 계정을 지웠으면 그 계정 몬스터 기록을 이 기기에서도 지운다(기기 세션 장부는 남긴다 — 서버로 가지 않는다).
    func forgetAccount(uid: String) {
        ledger.encounters.removeAll { $0.ownerUID == uid }
        ledger.mergedUIDs.removeAll { $0 == uid }
        stats = nil
        rank = nil
        if bestiaryOwner == uid {
            bestiaryOwner = nil
            bestiaryKills = nil
        }
        save()
    }

    /// 1시간 스로틀로 `config/monster`를 받아 캐시한다.
    func refreshConfigIfNeeded() async {
        let last = defaults.object(forKey: Self.configFetchedAtKey) as? Date
        guard last.map({ Date().timeIntervalSince($0) > Self.configRefreshInterval }) ?? true,
              api != nil else { return }
        defaults.set(Date(), forKey: Self.configFetchedAtKey)
        guard let payload = await MonsterConfigClient.fetchPayload(),
              let fresh = MonsterConfigDecoder.decodePayload(payload) else { return }
        config = fresh
        defaults.set(payload, forKey: Self.configCacheKey)
    }

    private func save() {
        guard !env.isDemo() else { return }
        storage.save(ledger)
    }
}

/// 앱이 지금 화면 앞에 있는지(백그라운드 갱신에서는 서버에 출현을 요청하지 않는다).
enum UIApplicationStateProbe {
    static var isActive: Bool { UIApplication.shared.applicationState == .active }
}
