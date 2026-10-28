//
//  MonsterStoreTests.swift
//  TokenWatchTests
//
//  몬스터 상태 머신 검증(가짜 계정·가짜 서버·메모리 저장소).
//  - 게스트: 100% 창에 한 번만 출현, 새로고침 반복에도 그대로, 백그라운드·크리터 끔·데모는 출현 없음
//  - 타격: 디바운스 간격 안 연타 무시, HP 0이면 처치·게스트 처치 수 기록
//  - 계정(동의 완료): 서버 출현 요청(보내는 키 목록 — 사용률 수치 없음), 같은 세션 재요청 없음,
//    기기 세션 장부가 다른 uid 것이면 요청하지 않음, consent_required면 동의 요청 상태
//  - 처치 확정: 오프라인이면 미확정으로 남고 다음에 다시 보낸다
//  - 확률 출현(§15-11): 에이전트마다 따로, 처음 보이면 일정만, 20~40분 뒤 추첨, 서버가 정한 다음 시각을 따른다,
//    100% 창은 완료 몬스터를 잡은 뒤부터 후보, 유령은 처치 뒤 1시간, 새 몬스터는 몬스터·유령이 없는 바로
//    (빈 바가 없으면 유령 바에 나오고 그 유령을 치운다), 세션 창의 슬라임은 파랑 슬라임(HP 2·15점)
//  - 계정 삭제 뒤 그 계정 기록을 지운다
//

import Foundation
import Testing
@testable import TokenWatch

final class MemoryLedger: MonsterLedgerStorage {
    var state: MonsterLedgerState?
    var saves = 0
    func load() -> MonsterLedgerState? { state }
    func save(_ state: MonsterLedgerState) { self.state = state; saves += 1 }
}

final class MemorySessionLedger: DeviceSessionLedgerStorage {
    var state = DeviceSessionLedgerState()
    func load() -> DeviceSessionLedgerState { state }
    func save(_ state: DeviceSessionLedgerState) { self.state = state }
}

/// callable 가짜 서버 — 함수 이름별 응답, 요청 본문 기록.
@MainActor
final class FakeFunctions {
    var responses: [String: [(status: Int, body: String)]] = [:]
    var failTransport = false
    private(set) var calls: [(name: String, data: [String: Any])] = []

    func handle(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if failTransport { throw URLError(.notConnectedToInternet) }
        let name = request.url?.lastPathComponent ?? ""
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
        calls.append((name, body?["data"] as? [String: Any] ?? [:]))
        var queue = responses[name] ?? []
        let r = queue.isEmpty ? (status: 500, body: "{}") : queue.removeFirst()
        responses[name] = queue
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        return (Data(r.body.utf8), http)
    }

    func count(_ name: String) -> Int { calls.filter { $0.name == name }.count }
}

@MainActor
struct MonsterStoreTests {
    private final class Clock { var ms: Int64 = 1_800_000_000_000 }

    private let user = AccountUser(uid: "u1", methods: [.apple])
    private let agent = Agent(provider: .claude)

    private static func profileJSON(terms: Int) -> String {
        """
        {"fields":{"nickname":{"stringValue":"모험가"},"nicknameLower":{"stringValue":"모험가"},"tag":{"stringValue":"0042"},
          "nicknameChangedAtMs":{"integerValue":"1"},"createdAtMs":{"integerValue":"1"},
          "termsAcceptedVersion":{"integerValue":"\(terms)"},
          "avatar":{"mapValue":{"fields":{"kind":{"stringValue":"preset"},"id":{"stringValue":"cat"}}}}}}
        """
    }

    private func fullWindow(_ clock: Clock, label: String = "Current week (all models)") -> UsageWindow {
        UsageWindow(label: label, usedPercent: 100,
                    resetsAt: Date(timeIntervalSince1970: Double(clock.ms) / 1000 + 86_400), kind: .weekly)
    }

    /// 확률 출현 후보를 모으는 전 에이전트 스냅숏(테스트가 바꿔 끼운다).
    private final class Snapshots { var list: [(agent: Agent, windows: [UsageWindow])] = [] }

    private struct Setup {
        let store: MonsterStore
        let account: AccountStore
        let functions: FakeFunctions
        let ledger: MemoryLedger
        let session: MemorySessionLedger
        let clock: Clock
        let snapshots: Snapshots
    }

    /// signedIn: nil이면 게스트, 값이 있으면 그 약관 버전으로 로그인.
    /// configPayload: 캐시된 서버 설정(JSON 문자열)로 시작한다.
    private func makeSetup(signedInTerms: Int? = nil, foreground: Bool = true, critters: Bool = true,
                           demo: Bool = false, configPayload: String? = nil, suite: String = #function) async -> Setup {
        let defaults = UserDefaults(suiteName: "MonsterStoreTests.\(suite)")!
        defaults.removePersistentDomain(forName: "MonsterStoreTests.\(suite)")
        if let configPayload {
            // 방금 받은 것으로 둬서 운영 설정을 내려받아 덮어쓰지 않게 한다.
            defaults.set(Data(configPayload.utf8), forKey: "tokenwatch.monster.config.v1")
            defaults.set(Date(), forKey: "tokenwatch.monster.configFetchedAt")
        }
        let auth = FakeAccountAuth()
        let firestore = FakeFirestore()
        let account = AccountStore(auth: auth, projectID: "demo-proj", transport: { try await firestore.handle($0) },
                                   isDemo: { demo }, defaults: defaults)
        account.start()
        if let terms = signedInTerms {
            auth.signInResult = .success(user, isNew: false)
            firestore.responses = [.init(status: 200, body: Self.profileJSON(terms: terms))]
            await account.signIn(with: .apple)
        }
        let functions = FakeFunctions()
        let api = MonsterAPIClient(projectID: "demo-proj", apiKey: nil,
                                   token: { _ in auth.currentUser == nil ? nil : "token" },
                                   transport: { try await functions.handle($0) }, appVersion: "2.0.0")
        let clock = Clock()
        let ledger = MemoryLedger()
        let session = MemorySessionLedger()
        let snapshots = Snapshots()
        snapshots.list = [(agent, [])]
        let env = MonsterStore.Environment(
            isDemo: { demo }, crittersEnabled: { critters }, isForeground: { foreground },
            nowMs: { clock.ms }, appVersion: "2.0.0", snapshots: { snapshots.list })
        let store = MonsterStore(account: account, api: api, environment: env, storage: ledger,
                                 sessionStorage: session, defaults: defaults)
        return Setup(store: store, account: account, functions: functions, ledger: ledger, session: session, clock: clock,
                     snapshots: snapshots)
    }

    private func partialWindow(_ clock: Clock, label: String = "Current session") -> UsageWindow {
        UsageWindow(label: label, usedPercent: 40,
                    resetsAt: Date(timeIntervalSince1970: Double(clock.ms) / 1000 + 3600), kind: .session)
    }

    /// HP가 다 닳을 때까지 디바운스 간격을 두고 때린다(세션 창의 파랑 슬라임은 HP 2). 마지막 결과를 돌려준다.
    @discardableResult
    private func kill(_ s: Setup, _ key: String) -> MonsterStore.HitResult {
        var result = s.store.hit(key: key)
        while case .damaged = result {
            s.clock.ms += 200
            result = s.store.hit(key: key)
        }
        return result
    }

    // MARK: 게스트

    @Test func guestCompletionSpawnsOnce() async {
        let s = await makeSetup()
        let w = fullWindow(s.clock)
        await s.store.observe(agent: agent, windows: [w])
        await s.store.observe(agent: agent, windows: [w])
        let shown = s.store.encounters(agentID: agent.id, provider: .claude, window: w)
        #expect(shown.count == 1)
        #expect(shown.first?.ownerUID == nil)
        #expect(shown.first?.monsterID == "slime")   // 첫 3회는 common
        #expect(s.functions.calls.isEmpty)            // 게스트는 서버를 부르지 않는다
        #expect(s.ledger.saves > 0)
    }

    @Test func noSpawnInBackgroundWithCrittersOffOrInDemo() async {
        for (fg, critters, demo) in [(false, true, false), (true, false, false), (true, true, true)] {
            let s = await makeSetup(foreground: fg, critters: critters, demo: demo, suite: "bg\(fg)\(critters)\(demo)")
            let w = fullWindow(s.clock)
            await s.store.observe(agent: agent, windows: [w])
            #expect(s.store.ledger.encounters.isEmpty)
        }
    }

    @Test func demoShowsMemoryOnlySampleMonster() async {
        let s = await makeSetup(demo: true)
        let w = fullWindow(s.clock)
        let shown = s.store.encounters(agentID: agent.id, provider: .claude, window: w)
        #expect(shown.count == 1)
        let key = shown[0].key
        if shown[0].maxHP > 1 {
            #expect(s.store.hit(key: key) == .damaged(remaining: shown[0].maxHP - 1))
        } else {
            #expect(s.store.hit(key: key) == .defeated)
        }
        #expect(s.ledger.saves == 0)
    }

    @Test func hitsAreDebouncedAndDefeatCountsForGuest() async {
        let s = await makeSetup()
        let w = fullWindow(s.clock)
        await s.store.observe(agent: agent, windows: [w])
        let key = s.store.ledger.encounters[0].key
        #expect(s.store.hit(key: key) == .defeated)            // 슬라임 HP 1
        #expect(s.store.hit(key: key) == .ignored)             // 이미 처치
        #expect(s.store.ledger.guest.kills["slime"] == 1)
        #expect(s.store.ledger.encounters[0].awardedScore == 10)
        // 처치된 몬스터도 리셋 전까지 엔젤링으로 보인다.
        #expect(s.store.encounters(agentID: agent.id, provider: .claude, window: w).first?.state == .defeated)
    }

    @Test func debounceIgnoresRapidTaps() async {
        let s = await makeSetup()
        // HP 3 몬스터를 직접 넣어 연타 간격을 본다.
        let goblin = MonsterEncounter(key: "g", ownerUID: nil, source: .completion, provider: "claude",
                                      windowLabel: "w", resetBucketMs: 0, drawAtMs: nil, monsterID: "goblin",
                                      maxHP: 3, hp: 3, state: .alive, spawnedAtMs: s.clock.ms,
                                      expiresAtMs: s.clock.ms + 1_000_000, position: 0.5)
        s.ledger.state = MonsterLedgerState(encounters: [goblin])
        let fresh = MonsterStore(account: s.account, api: nil,
                                 environment: .init(isDemo: { false }, crittersEnabled: { true }, isForeground: { true },
                                                    nowMs: { s.clock.ms }, appVersion: "2.0.0", snapshots: { [] }),
                                 storage: s.ledger, sessionStorage: s.session)
        #expect(fresh.hit(key: "g") == .damaged(remaining: 2))
        s.clock.ms += 50
        #expect(fresh.hit(key: "g") == .ignored)
        s.clock.ms += 200
        #expect(fresh.hit(key: "g") == .damaged(remaining: 1))
        s.clock.ms += 200
        #expect(fresh.hit(key: "g") == .defeated)
        #expect(fresh.ledger.guest.nextCommonGuaranteed)       // 특수 처치 → 다음은 common
    }

    // MARK: 확률 출현(§15-11)

    /// 확률 100% 설정 — 추첨하면 반드시 나온다.
    private static let alwaysRandom = #"{"spawn":{"random":{"chancePerSlot":1}}}"#

    @Test func guestRandomWaitsTwentyToFortyMinutesThenDraws() async throws {
        let s = await makeSetup(configPayload: Self.alwaysRandom)
        let w = partialWindow(s.clock)
        s.snapshots.list = [(agent, [w])]
        let start = s.clock.ms
        await s.store.observe(agent: agent, windows: [w])
        #expect(s.store.ledger.encounters.isEmpty)                 // 처음 보이면 일정만 정한다
        let due = try #require(s.store.ledger.nextDraw(agent: MonsterSessionKey.agentToken(agent.id)))
        #expect(due >= start + 20 * 60_000 && due <= start + 40 * 60_000)
        s.clock.ms = due - 1
        await s.store.observe(agent: agent, windows: [w])
        #expect(s.store.ledger.encounters.isEmpty)
        s.clock.ms = due
        await s.store.observe(agent: agent, windows: [w])
        #expect(s.store.ledger.encounters.count == 1)
        let e = try #require(s.store.ledger.encounters.first)
        #expect(e.source == .random && e.drawAtMs == due && e.agentID == agent.id && e.displayLabel == w.label)
        let next = try #require(s.store.ledger.nextDraw(agent: MonsterSessionKey.agentToken(agent.id)))
        #expect(next >= due + 20 * 60_000 && next <= due + 40 * 60_000)
        #expect(s.functions.calls.isEmpty)
    }

    @Test func guestSessionBarSlimeIsTheBlueSlime() async throws {
        let s = await makeSetup(configPayload: Self.alwaysRandom)
        let session = partialWindow(s.clock)
        s.snapshots.list = [(agent, [session])]
        let e = try await drawOnce(s, windows: [session])            // 첫 3회는 common → 세션 창이라 파랑 슬라임
        #expect(e.monsterID == "slime-sky" && e.maxHP == 2 && e.hp == 2)
        #expect(s.store.hit(key: e.key) == .damaged(remaining: 1))
        s.clock.ms += 200
        #expect(s.store.hit(key: e.key) == .defeated)
        #expect(s.store.ledger.encounters.first { $0.key == e.key }?.awardedScore == 15)
        #expect(s.store.ledger.guest.kills["slime-sky"] == 1 && s.store.ledger.guest.kills["slime"] == nil)
        // 주간 창 완료 출현은 그대로 슬라임.
        let week = fullWindow(s.clock)
        await s.store.observe(agent: agent, windows: [week])
        #expect(s.store.encounters(agentID: agent.id, provider: .claude, window: week).first?.monsterID == "slime")
    }

    @Test func eachAgentDrawsOnItsOwn() async {
        let s = await makeSetup(configPayload: Self.alwaysRandom)
        let second = Agent(provider: .claude)
        let third = Agent(provider: .codex)
        let w = partialWindow(s.clock)
        let other = UsageWindow(label: w.label, usedPercent: 70, resetsAt: w.resetsAt, kind: .session)   // 다른 계정
        s.snapshots.list = [(agent, [w]), (second, [other]), (third, [w])]
        await s.store.observe(agent: agent, windows: [w])
        #expect(s.store.ledger.randomSchedule?.count == 3)
        s.clock.ms += 40 * 60_000
        await s.store.observe(agent: agent, windows: [w])
        #expect(Set(s.store.ledger.encounters.compactMap(\.agentID)) == [agent.id, second.id, third.id])
    }

    @Test func sameAccountAddedTwiceDrawsOnce() async {
        let s = await makeSetup(configPayload: Self.alwaysRandom)
        let copy = Agent(provider: .claude)
        let w = partialWindow(s.clock)
        s.snapshots.list = [(agent, [w]), (copy, [w])]                // 창 숫자·리셋이 똑같다 = 같은 계정
        await s.store.observe(agent: agent, windows: [w])
        #expect(s.store.ledger.randomSchedule?.keys.sorted() == [MonsterSessionKey.agentToken(agent.id)])
        s.clock.ms += 40 * 60_000
        await s.store.observe(agent: agent, windows: [w])
        #expect(s.store.ledger.encounters.compactMap(\.agentID) == [agent.id])
    }

    @Test func unusedWindowWaitsForTheFirstUse() async {
        let s = await makeSetup(configPayload: Self.alwaysRandom)
        let unused = UsageWindow(label: "Current week (all models)", usedPercent: 0,
                                 resetsAt: Date(timeIntervalSince1970: Double(s.clock.ms) / 1000 + 86_400), kind: .weekly)
        s.snapshots.list = [(agent, [unused])]                        // 기본 최소 사용률 1% 미만
        await s.store.observe(agent: agent, windows: [unused])
        #expect(s.store.ledger.nextDraw(agent: MonsterSessionKey.agentToken(agent.id)) == nil)
    }

    @Test func fullWindowJoinsTheDrawOnceItsCompletionMonsterIsDefeated() async throws {
        let s = await makeSetup(configPayload: Self.alwaysRandom)
        let w = fullWindow(s.clock)
        s.snapshots.list = [(agent, [w])]
        let token = MonsterSessionKey.agentToken(agent.id)
        await s.store.observe(agent: agent, windows: [w])
        let completion = try #require(s.store.ledger.encounters.first)
        #expect(completion.source == .completion && s.store.ledger.encounters.count == 1)
        #expect(s.store.ledger.nextDraw(agent: token) == nil)          // 완료 몬스터가 살아 있으면 후보가 아니다
        #expect(s.store.hit(key: completion.key) == .defeated)         // 첫 3회는 HP 1 슬라임
        await s.store.observe(agent: agent, windows: [w])
        let due = try #require(s.store.ledger.nextDraw(agent: token))  // 잡은 뒤부터 일정이 흐른다
        s.clock.ms = due
        await s.store.observe(agent: agent, windows: [w])
        let random = try #require(s.store.ledger.encounters.first { $0.source == .random })
        #expect(random.agentID == agent.id && random.displayLabel == w.label)
    }

    /// 첫 관찰로 일정을 정한 뒤 예정 시각에 한 번 더 관찰해 확률 몬스터를 하나 받는다.
    private func drawOnce(_ s: Setup, windows: [UsageWindow]) async throws -> MonsterEncounter {
        let token = MonsterSessionKey.agentToken(agent.id)
        if s.store.ledger.nextDraw(agent: token) == nil { await s.store.observe(agent: agent, windows: windows) }
        let before = Set(s.store.ledger.encounters.map(\.key))
        s.clock.ms = try #require(s.store.ledger.nextDraw(agent: token))
        await s.store.observe(agent: agent, windows: windows)
        return try #require(s.store.ledger.encounters.first { !before.contains($0.key) && $0.source == .random })
    }

    @Test func randomGhostStaysAnHourAfterTheKill() async throws {
        let s = await makeSetup(configPayload: Self.alwaysRandom)
        let w = partialWindow(s.clock)
        s.snapshots.list = [(agent, [w])]
        let e = try await drawOnce(s, windows: [w])
        s.clock.ms += 30 * 60_000
        #expect(kill(s, e.key) == .defeated)
        let killedAt = s.clock.ms
        s.clock.ms = killedAt + 50 * 60_000                         // 살아 있던 한도(출현 + 60분)는 지났다
        #expect(s.store.encounters(agentID: agent.id, provider: .claude, window: w).map(\.key) == [e.key])
        s.clock.ms = killedAt + 60 * 60_000
        #expect(s.store.encounters(agentID: agent.id, provider: .claude, window: w).isEmpty)
    }

    @Test func nextMonsterAvoidsBarsWithAMonsterOrAGhost() async throws {
        let s = await makeSetup(configPayload: Self.alwaysRandom)
        let session = partialWindow(s.clock)
        let week = UsageWindow(label: "Current week (all models)", usedPercent: 40,
                               resetsAt: Date(timeIntervalSince1970: Double(s.clock.ms) / 1000 + 86_400), kind: .weekly)
        let windows = [session, week]
        s.snapshots.list = [(agent, windows)]
        let first = try await drawOnce(s, windows: windows)
        let second = try await drawOnce(s, windows: windows)       // 40분 안이라 첫 몬스터는 아직 살아 있다
        #expect(second.displayLabel != first.displayLabel)          // 몬스터가 있는 바는 피한다
        #expect(kill(s, first.key) == .defeated)
        #expect(kill(s, second.key) == .defeated)
        let third = try await drawOnce(s, windows: windows)        // 두 바 모두 1시간 안의 유령 → 그중 한 바에 나온다
        let thirdBar = try #require(windows.first { $0.label == third.displayLabel })
        let otherBar = try #require(windows.first { $0.label != third.displayLabel })
        #expect(s.store.encounters(agentID: agent.id, provider: .claude, window: thirdBar).map(\.key) == [third.key])
        #expect(s.store.encounters(agentID: agent.id, provider: .claude, window: otherBar).count == 1)   // 다른 유령은 그대로
    }

    @Test func singleBarGhostMakesWayForTheNextMonster() async throws {
        let s = await makeSetup(configPayload: Self.alwaysRandom)
        let w = partialWindow(s.clock)
        s.snapshots.list = [(agent, [w])]
        let token = MonsterSessionKey.agentToken(agent.id)
        let first = try await drawOnce(s, windows: [w])
        // 살아 있는 동안 다음 예정 시각이 오면 추첨하지 않고 일정을 그대로 둔다.
        let due = try #require(s.store.ledger.nextDraw(agent: token))
        s.clock.ms = due
        await s.store.observe(agent: agent, windows: [w])
        #expect(s.store.ledger.encounters.count == 1 && s.store.ledger.nextDraw(agent: token) == due)
        #expect(kill(s, first.key) == .defeated)
        let next = try await drawOnce(s, windows: [w])               // 바가 하나뿐이면 유령 바에 나온다
        let shown = s.store.encounters(agentID: agent.id, provider: .claude, window: w)
        #expect(shown.map(\.key) == [next.key] && shown.first?.isAlive == true)   // 유령은 비켜 준다
        #expect(s.store.ledger.encounters.first { $0.key == first.key }?.dismissedAtMs != nil)
    }

    @Test func agentWithoutCandidateWindowIsSkipped() async {
        let s = await makeSetup(configPayload: Self.alwaysRandom)
        let credit = UsageWindow(label: "credits", usedPercent: 40,
                                 resetsAt: Date(timeIntervalSince1970: Double(s.clock.ms) / 1000 + 86_400),
                                 kind: .weekly, style: .creditGauge)
        s.snapshots.list = [(agent, [credit])]                        // 충전형 게이지는 대상이 아니다
        await s.store.observe(agent: agent, windows: [])
        #expect(s.store.ledger.nextDraw(agent: MonsterSessionKey.agentToken(agent.id)) == nil)
    }

    // MARK: 계정

    private static func encounterJSON(key: String, monster: String = "goblin", state: String = "alive") -> String {
        #"{"result":{"encounter":{"key":"\#(key)","source":"completion","provider":"claude","windowLabel":"Current week (all models)","resetBucketMs":1800086400000,"monsterId":"\#(monster)","maxHP":3,"state":"\#(state)","spawnedAtMs":1800000000000,"expiresAtMs":1800086400000}}}"#
    }

    @Test func consentedAccountAsksTheServerOncePerSession() async throws {
        let s = await makeSetup(signedInTerms: 2)
        #expect(s.store.activeOwner == "u1")
        let w = fullWindow(s.clock)
        let key = MonsterSessionKey.completionKey(uid: "u1", provider: .claude, resetBucketMs: 1_800_086_400_000)
        s.functions.responses["spawnEncounter"] = [(200, Self.encounterJSON(key: key))]
        await s.store.observe(agent: agent, windows: [w])
        await s.store.observe(agent: agent, windows: [w])
        #expect(s.functions.count("spawnEncounter") == 1)
        let sent = try #require(s.functions.calls.first { $0.name == "spawnEncounter" }?.data)
        #expect(Set(sent.keys) == ["source", "provider", "windowLabel", "periodSec", "session", "resetBucketMs",
                                   "resetsAtMs", "platform", "appVersion", "spriteFormat"])   // 사용률 수치·계정 정보 없음
        #expect(sent["periodSec"] as? Int == 604_800)
        #expect(sent["session"] as? Bool == false)
        let shown = s.store.encounters(agentID: agent.id, provider: .claude, window: w)
        #expect(shown.first?.monsterID == "goblin" && shown.first?.ownerUID == "u1")
        // 기기 세션 장부에 이 세션이 u1 것으로 남는다.
        #expect(s.session.state.entries["claude|1800086400000"]?.uid == "u1")
    }

    @Test func accountRandomFollowsTheServerSchedule() async throws {
        let s = await makeSetup(signedInTerms: 2)
        let w = partialWindow(s.clock)
        s.snapshots.list = [(agent, [w])]
        let first = s.clock.ms + 25 * 60_000
        let key = MonsterSessionKey.randomKey(uid: "u1", agentKey: "k", drawAtMs: first)
        s.functions.responses["spawnEncounter"] = [
            (200, #"{"result":{"encounter":null,"nextDrawAtMs":\#(first)}}"#),
            (200, #"{"result":{"encounter":{"key":"\#(key)","source":"random","provider":"claude","windowLabel":"Current session","drawAtMs":\#(first),"monsterId":"slime","maxHP":1,"state":"alive","spawnedAtMs":\#(first),"expiresAtMs":\#(first + 3_600_000)},"nextDrawAtMs":\#(first + 30 * 60_000)}}"#),
        ]
        await s.store.observe(agent: agent, windows: [w])            // 처음: 서버에 등록만
        #expect(s.functions.count("spawnEncounter") == 1)
        let sent = try #require(s.functions.calls.first { $0.name == "spawnEncounter" }?.data)
        #expect(Set(sent.keys) == ["source", "agentKey", "candidates", "platform", "appVersion", "spriteFormat"])
        let sentCandidates = try #require(sent["candidates"] as? [[String: Any]])
        #expect(sentCandidates.count == 1 && Set(sentCandidates[0].keys) == ["provider", "windowLabel", "session"])
        #expect(sentCandidates[0]["session"] as? Bool == true)
        #expect(sent["agentKey"] as? String
                == MonsterSessionKey.agentKey(uid: "u1", agentToken: MonsterSessionKey.agentToken(agent.id)))
        #expect(s.store.ledger.nextDraw(agent: MonsterSessionKey.agentToken(agent.id)) == first)
        s.clock.ms = first - 1
        await s.store.observe(agent: agent, windows: [w])
        #expect(s.functions.count("spawnEncounter") == 1)             // 예정 전에는 묻지 않는다
        s.clock.ms = first
        await s.store.observe(agent: agent, windows: [w])
        #expect(s.functions.count("spawnEncounter") == 2)
        let shown = s.store.encounters(agentID: agent.id, provider: .claude, window: w)
        #expect(shown.first?.key == key && shown.first?.ownerUID == "u1")
        #expect(s.store.ledger.nextDraw(agent: MonsterSessionKey.agentToken(agent.id)) == first + 30 * 60_000)
    }

    @Test func deviceScheduleHoldsAfterSwitchingAccounts() async {
        // 다른 계정이 이 기기에서 방금 뽑았으면, 새 계정도 그 일정이 올 때까지 묻지 않는다.
        let s = await makeSetup(signedInTerms: 2)
        let w = partialWindow(s.clock)
        s.snapshots.list = [(agent, [w])]
        var state = MonsterLedgerState()
        state.setNextDraw(s.clock.ms + 10 * 60_000, agent: MonsterSessionKey.agentToken(agent.id), nowMs: s.clock.ms)
        s.ledger.state = state
        let fresh = MonsterStore(account: s.account, api: MonsterAPIClient(
                                    projectID: "demo-proj", apiKey: nil, token: { _ in "token" },
                                    transport: { try await s.functions.handle($0) }, appVersion: "2.0.0"),
                                 environment: .init(isDemo: { false }, crittersEnabled: { true }, isForeground: { true },
                                                    nowMs: { s.clock.ms }, appVersion: "2.0.0",
                                                    snapshots: { s.snapshots.list }),
                                 storage: s.ledger, sessionStorage: s.session)
        await fresh.observe(agent: agent, windows: [w])
        #expect(s.functions.count("spawnEncounter") == 0)
    }

    @Test func sessionLedgerBlocksAnotherAccount() async {
        let s = await makeSetup(signedInTerms: 2)
        s.session.state.entries["claude|1800086400000"] = .init(uid: "someone-else", atMs: s.clock.ms)
        await s.store.observe(agent: agent, windows: [fullWindow(s.clock)])
        #expect(s.functions.count("spawnEncounter") == 0)
    }

    @Test func accountWithoutConsentStaysGuest() async {
        let s = await makeSetup(signedInTerms: 1)
        #expect(s.store.activeOwner == nil)
        #expect(s.store.needsConsent)
        await s.store.observe(agent: agent, windows: [fullWindow(s.clock)])
        #expect(s.functions.count("spawnEncounter") == 0)
        #expect(s.store.ledger.encounters.first?.ownerUID == nil)
    }

    @Test func consentRequiredFromServerIsRemembered() async {
        let s = await makeSetup(signedInTerms: 2)
        s.functions.responses["spawnEncounter"] = [(400, #"{"error":{"status":"FAILED_PRECONDITION","details":{"code":"consent_required"}}}"#)]
        await s.store.observe(agent: agent, windows: [fullWindow(s.clock)])
        #expect(s.store.consentRequested)
        #expect(s.store.ledger.encounters.isEmpty)
    }

    @Test func acceptConsentUpdatesProfileAndMergesGuestHistory() async {
        let s = await makeSetup(signedInTerms: 1)
        // 게스트로 슬라임 하나 처치.
        let w = fullWindow(s.clock)
        await s.store.observe(agent: agent, windows: [w])
        s.store.hit(key: s.store.ledger.encounters[0].key)
        s.functions.responses["acceptTerms"] = [(200, #"{"result":{"termsAcceptedVersion":2}}"#)]
        s.functions.responses["mergeGuestHistory"] = [(200, #"{"result":{"merged":true}}"#)]
        #expect(await s.store.acceptConsent())
        #expect(s.account.profile?.termsAcceptedVersion == 2)
        #expect(s.store.activeOwner == "u1")
        let merged = s.functions.calls.first { $0.name == "mergeGuestHistory" }?.data["kills"] as? [String: Int]
        #expect(merged == ["slime": 1])
        #expect(s.store.ledger.mergedUIDs == ["u1"])
    }

    @Test func defeatStaysPendingWhileOffline() async {
        let s = await makeSetup(signedInTerms: 2)
        let key = MonsterSessionKey.completionKey(uid: "u1", provider: .claude, resetBucketMs: 1_800_086_400_000)
        s.functions.responses["spawnEncounter"] = [(200, Self.encounterJSON(key: key))]
        let w = fullWindow(s.clock)
        await s.store.observe(agent: agent, windows: [w])
        for _ in 0..<3 {
            s.clock.ms += 500
            s.store.hit(key: key)
        }
        s.functions.failTransport = true
        await s.store.sendDefeat(key: key)
        #expect(s.store.ledger.encounters.first { $0.key == key }?.pendingDefeat == true)
        s.functions.failTransport = false
        s.functions.responses["defeatEncounter"] = [(200, #"{"result":{"encounter":{"key":"\#(key)","source":"completion","provider":"claude","windowLabel":"w","monsterId":"goblin","maxHP":3,"state":"defeated","spawnedAtMs":1,"expiresAtMs":2,"awardedScore":50},"stats":{"totalScore":50,"commonKills":0,"specialKills":1}}}"#)]
        await s.store.sendDefeat(key: key)
        let e = s.store.ledger.encounters.first { $0.key == key }
        #expect(e?.pendingDefeat == false && e?.awardedScore == 50)
        #expect(s.store.stats == MonsterStatsDTO(totalScore: 50, commonKills: 0, specialKills: 1))
    }

    @Test func forgettingAnAccountRemovesItsMonsters() async {
        let s = await makeSetup(signedInTerms: 2)
        let key = MonsterSessionKey.completionKey(uid: "u1", provider: .claude, resetBucketMs: 1_800_086_400_000)
        s.functions.responses["spawnEncounter"] = [(200, Self.encounterJSON(key: key))]
        await s.store.observe(agent: agent, windows: [fullWindow(s.clock)])
        #expect(!s.store.ledger.encounters.isEmpty)
        s.store.forgetAccount(uid: "u1")
        #expect(s.store.ledger.encounters.isEmpty)
    }
}
