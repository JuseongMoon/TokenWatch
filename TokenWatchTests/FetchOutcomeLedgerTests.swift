//
//  FetchOutcomeLedgerTests.swift
//  TokenWatchTests
//
//  조회 오류 전이 상태를 기기에 저장한 회귀: 앱을 다시 띄워도 같은 오류를 또 보내지 않고,
//  사유가 바뀌면 새 오류로, 오류→정상이면 복구로 한 번씩만 보낸다. 분석 수집 OFF 중에는 기준을
//  갱신하지 않고, 다시 켠 뒤 첫 결과는 기준만 잡는다. 카드를 지우면 상태를 지우고,
//  데모 진입 때는 모든 카드를 `paused`로 표시해 데모를 나온 뒤 첫 결과는 기준만 잡는다.
//  격리된 UserDefaults와 가짜 조회·이벤트 기록기를 쓴다(실제 저장 데이터·네트워크·분석 전송 없음).
//

import Testing
import Foundation
@testable import TokenWatch

/// 보낸 전이 이벤트를 모으는 가짜 분석 경로.
@MainActor
private final class EventRecorder {
    var collecting = true
    private(set) var events: [String] = []

    var analytics: FetchOutcomeAnalytics {
        FetchOutcomeAnalytics(
            isCollecting: { [unowned self] in collecting },
            log: { [unowned self] event in
                let reason = event.parameters["reason"] as? String
                events.append(reason.map { "\(event.name):\($0)" } ?? event.name)
            })
    }
}

@MainActor
struct FetchOutcomeLedgerTests {
    private typealias F = AuthFixtures
    private typealias L = FetchOutcomeLedger

    // MARK: 전이 판정(순수)

    @Test func 전이_규칙() {
        let cases: [(String?, FetchErrorReason?, L.Transition?)] = [
            (nil, .auth, .error(.auth)),               // 없음 → 오류
            ("ok", .network, .error(.network)),        // ok → 오류
            ("auth", .auth, nil),                       // 같은 오류 유지
            ("auth", .rateLimit, .error(.rateLimit)),   // 다른 사유 → 새 오류
            ("auth", nil, .recover),                    // 오류 → ok
            ("ok", nil, nil),                           // ok 유지
            (nil, nil, nil),                            // 없음 → ok: 기준만
            ("paused", .auth, nil),                     // 수집 재개 뒤 첫 결과: 기준만
            ("paused", nil, nil),
        ]
        for (previous, current, expected) in cases {
            #expect(L.transition(previous: previous, current: current) == expected,
                    "\(previous ?? "nil") → \(current?.rawValue ?? "ok")")
        }
    }

    // MARK: 원장

    @Test func 앱을_다시_띄워도_같은_오류는_다시_보내지_않는다() {
        let defaults = F.isolatedDefaults(), id = UUID()
        #expect(L(defaults: defaults).record(.auth, for: id, collecting: true) == .error(.auth))
        // 재실행 = 같은 저장소의 새 인스턴스.
        let relaunched = L(defaults: defaults)
        #expect(relaunched.record(.auth, for: id, collecting: true) == nil)
        #expect(relaunched.record(nil, for: id, collecting: true) == .recover)
        #expect(L(defaults: defaults).record(nil, for: id, collecting: true) == nil)
    }

    @Test func 수집이_꺼진_동안은_기준을_갱신하지_않고_다시_켠_뒤_첫_결과는_기준만_잡는다() {
        let ledger = L(defaults: F.isolatedDefaults()), id = UUID()
        #expect(ledger.record(.auth, for: id, collecting: true) == .error(.auth))

        // OFF 중 복구 — 이벤트도, 기준 갱신도 없다(기준을 모름으로만 표시).
        #expect(ledger.record(nil, for: id, collecting: false) == nil)
        #expect(ledger.value(for: id) == L.pausedValue)

        // ON 뒤 첫 결과: 기준만 저장(짝 없는 recover를 보내지 않는다).
        #expect(ledger.record(nil, for: id, collecting: true) == nil)
        #expect(ledger.value(for: id) == L.okValue)
        // 그 다음 변화부터는 평소대로.
        #expect(ledger.record(.http5xx, for: id, collecting: true) == .error(.http5xx))
    }

    @Test func OFF_중에_처음_본_카드도_ON_뒤_첫_결과는_기준만_잡는다() {
        let ledger = L(defaults: F.isolatedDefaults()), id = UUID()
        #expect(ledger.record(.auth, for: id, collecting: false) == nil)
        #expect(ledger.record(.auth, for: id, collecting: true) == nil)
        #expect(ledger.record(nil, for: id, collecting: true) == .recover)
    }

    @Test func 저장_값은_열거_문자열뿐이다() {
        let defaults = F.isolatedDefaults(), ledger = L(defaults: defaults)
        _ = ledger.record(.credential, for: UUID(), collecting: true)
        _ = ledger.record(nil, for: UUID(), collecting: true)
        _ = ledger.record(.parse, for: UUID(), collecting: false)
        let stored = defaults.dictionary(forKey: L.storageKey) as? [String: String] ?? [:]
        let allowed = Set(["ok", "paused", "auth", "rate_limit", "http_4xx", "http_5xx",
                           "network", "parse", "empty", "credential", "other"])
        #expect(stored.count == 3)
        #expect(Set(stored.values).isSubset(of: allowed))
        #expect(stored.keys.allSatisfy { UUID(uuidString: $0) != nil })
    }

    @Test func 지우면_다음_오류는_새로_센다() {
        let defaults = F.isolatedDefaults(), ledger = L(defaults: defaults)
        let a = UUID(), b = UUID()
        _ = ledger.record(.auth, for: a, collecting: true)
        _ = ledger.record(.auth, for: b, collecting: true)
        ledger.remove([a])
        #expect(ledger.value(for: a) == nil)
        #expect(ledger.value(for: b) == "auth")
        #expect(ledger.record(.auth, for: a, collecting: true) == .error(.auth))
        ledger.remove([a, b])
        #expect(defaults.object(forKey: L.storageKey) == nil)
    }

    @Test func 모두_paused로_표시하면_각_카드의_다음_결과는_기준만_잡는다() {
        let ledger = L(defaults: F.isolatedDefaults())
        let erroring = UUID(), healthy = UUID(), unseen = UUID()
        _ = ledger.record(.auth, for: erroring, collecting: true)
        _ = ledger.record(nil, for: healthy, collecting: true)
        ledger.markAllPaused([erroring, unseen])   // healthy는 저장돼 있어 함께 표시된다
        for id in [erroring, healthy, unseen] { #expect(ledger.value(for: id) == L.pausedValue) }

        #expect(ledger.record(.auth, for: erroring, collecting: true) == nil)   // 같은 오류 재전송 없음
        #expect(ledger.record(.network, for: healthy, collecting: true) == nil)
        #expect(ledger.record(.auth, for: unseen, collecting: true) == nil)
        #expect(ledger.record(nil, for: erroring, collecting: true) == .recover)
    }

    // MARK: AgentStore 연결

    private struct Harness {
        let store: AgentStore
        let fetcher: ScriptedFetcher
        let recorder: EventRecorder
        let agent: Agent
        let defaults: UserDefaults
    }

    /// - Parameters: 생략하면 새 격리 저장소·새 카드로 만든다. 재실행을 흉내 낼 때는 앞 하네스의 값을 넘긴다.
    private func makeHarness(defaults: UserDefaults? = nil, agent: Agent? = nil) -> Harness {
        let defaults = defaults ?? F.isolatedDefaults()
        let agent = agent ?? Agent(provider: .openrouter, accountLabel: "label")
        let recorder = EventRecorder()
        F.seedAgents([agent], into: defaults)
        let tokenStore = TokenStore(storage: MemoryCredentialStorage(),
                                    refresher: { _, _ in throw OAuthError.notAuthenticated })
        let fetcher = ScriptedFetcher()
        let store = AgentStore(defaults: defaults, tokenStore: tokenStore,
                               fetchSnapshot: { _, _, _ in await fetcher.fetch() },
                               copilotIdentity: { _ in nil },
                               fetchOutcomeAnalytics: recorder.analytics)
        return Harness(store: store, fetcher: fetcher, recorder: recorder, agent: agent, defaults: defaults)
    }

    /// 수동 새로고침 한 번을 주어진 결과로 끝낸다(수동이라 20초 스로틀을 건너뛴다).
    private func refresh(_ h: Harness, with snapshot: AgentSnapshot) async {
        let task = Task { await h.store.refresh(h.agent, manual: true) }
        await eventually { h.fetcher.pendingCount == 1 }
        h.fetcher.completeNext(snapshot)
        await task.value
    }

    private func error(_ reason: FetchErrorReason) -> AgentSnapshot {
        AgentSnapshot(windows: [], planLabel: nil, fetchedAt: Date(), error: "synthetic", errorReason: reason)
    }

    @Test func 스토어는_재실행해도_같은_오류를_다시_보내지_않고_복구를_한_번_보낸다() async {
        let first = makeHarness()
        await refresh(first, with: error(.auth))
        await refresh(first, with: error(.auth))
        #expect(first.recorder.events == ["usage_fetch_error:auth"])

        // 재실행: 같은 저장소로 새 스토어(메모리 스냅샷 없음).
        let relaunched = makeHarness(defaults: first.defaults, agent: first.agent)
        await refresh(relaunched, with: error(.auth))
        #expect(relaunched.recorder.events.isEmpty)
        await refresh(relaunched, with: F.okSnapshot())
        #expect(relaunched.recorder.events == ["usage_fetch_recover"])
    }

    @Test func 사유가_바뀌면_새_오류로_한_번_보낸다() async {
        let h = makeHarness()
        await refresh(h, with: error(.auth))
        await refresh(h, with: error(.credential))
        await refresh(h, with: error(.credential))
        #expect(h.recorder.events == ["usage_fetch_error:auth", "usage_fetch_error:credential"])
    }

    @Test func 지난_정상값_위에_오류만_덧입혀도_오류로_비교한다() async {
        let h = makeHarness()
        await refresh(h, with: F.okSnapshot())
        await refresh(h, with: error(.rateLimit))
        // 화면은 지난 그래프를 유지하지만(last-good) 전이는 오류다.
        #expect(h.store.snapshots[h.agent.id]?.windows.isEmpty == false)
        #expect(h.recorder.events == ["usage_fetch_error:rate_limit"])
    }

    @Test func 스토어는_수집_OFF_중_이벤트를_보내지_않고_ON_뒤_첫_결과는_기준만_잡는다() async {
        let h = makeHarness()
        await refresh(h, with: error(.auth))
        h.recorder.collecting = false
        await refresh(h, with: F.okSnapshot())
        #expect(h.recorder.events == ["usage_fetch_error:auth"])
        h.recorder.collecting = true
        await refresh(h, with: F.okSnapshot())
        #expect(h.recorder.events == ["usage_fetch_error:auth"])   // 짝 없는 recover 없음
        await refresh(h, with: error(.network))
        #expect(h.recorder.events == ["usage_fetch_error:auth", "usage_fetch_error:network"])
    }

    @Test func 카드를_지우면_상태도_지운다() async {
        let h = makeHarness()
        await refresh(h, with: error(.auth))
        #expect(FetchOutcomeLedger(defaults: h.defaults).value(for: h.agent.id) == "auth")
        h.store.remove(h.agent)
        #expect(FetchOutcomeLedger(defaults: h.defaults).value(for: h.agent.id) == nil)
    }

    @Test func 데모에_들어가면_모두_paused로_표시하고_나온_뒤_같은_오류를_다시_보내지_않는다() async {
        let h = makeHarness()
        await refresh(h, with: error(.auth))
        h.store.enterDemo()
        let ledger = FetchOutcomeLedger(defaults: h.defaults)
        #expect(ledger.value(for: h.agent.id) == FetchOutcomeLedger.pausedValue)

        await h.store.refreshAll()   // 데모 새로고침 — 조회도 기록도 없다
        #expect(h.fetcher.callCount == 1)
        #expect(ledger.value(for: h.agent.id) == FetchOutcomeLedger.pausedValue)

        h.store.exitDemo()
        await refresh(h, with: error(.auth))   // 데모 뒤 첫 결과: 기준만
        #expect(ledger.value(for: h.agent.id) == "auth")
        await refresh(h, with: F.okSnapshot())
        #expect(h.recorder.events == ["usage_fetch_error:auth", "usage_fetch_recover"])
    }
}
