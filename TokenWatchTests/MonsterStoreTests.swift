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

    private struct Setup {
        let store: MonsterStore
        let account: AccountStore
        let functions: FakeFunctions
        let ledger: MemoryLedger
        let session: MemorySessionLedger
        let clock: Clock
    }

    /// signedIn: nil이면 게스트, 값이 있으면 그 약관 버전으로 로그인.
    private func makeSetup(signedInTerms: Int? = nil, foreground: Bool = true, critters: Bool = true,
                           demo: Bool = false, suite: String = #function) async -> Setup {
        let defaults = UserDefaults(suiteName: "MonsterStoreTests.\(suite)")!
        defaults.removePersistentDomain(forName: "MonsterStoreTests.\(suite)")
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
        let agentRef = agent
        let env = MonsterStore.Environment(
            isDemo: { demo }, crittersEnabled: { critters }, isForeground: { foreground },
            nowMs: { clock.ms }, appVersion: "2.0.0", snapshots: { [(agentRef, [])] })
        let store = MonsterStore(account: account, api: api, environment: env, storage: ledger,
                                 sessionStorage: session, defaults: defaults)
        return Setup(store: store, account: account, functions: functions, ledger: ledger, session: session, clock: clock)
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
                                      windowLabel: "w", resetBucketMs: 0, slotStartMs: nil, monsterID: "goblin",
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
        #expect(Set(sent.keys) == ["source", "provider", "windowLabel", "periodSec", "resetBucketMs", "resetsAtMs",
                                   "platform", "appVersion", "spriteFormat"])   // 사용률 수치·계정 정보 없음
        #expect(sent["periodSec"] as? Int == 604_800)
        let shown = s.store.encounters(agentID: agent.id, provider: .claude, window: w)
        #expect(shown.first?.monsterID == "goblin" && shown.first?.ownerUID == "u1")
        // 기기 세션 장부에 이 세션이 u1 것으로 남는다.
        #expect(s.session.state.entries["claude|1800086400000"]?.uid == "u1")
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
