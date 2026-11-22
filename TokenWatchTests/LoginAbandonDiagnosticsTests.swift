//
//  LoginAbandonDiagnosticsTests.swift
//  TokenWatchTests
//
//  `login_abandon`의 `elapsed`·`attempt`(Android와 같은 의미) 회귀. 시계는 가짜를 주입한다.
//

import Testing
import Foundation
@testable import TokenWatch

@MainActor
struct LoginAbandonDiagnosticsTests {
    /// 앞으로 돌릴 수 있는 가짜 시계.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
    }

    @Test func elapsed_구간_경계() {
        let cases: [(TimeInterval, String)] = [
            (-5, "lt10s"), (0, "lt10s"), (9.999, "lt10s"),
            (10, "10_60s"), (30, "10_60s"), (60, "10_60s"),
            (60.001, "gt60s"), (3600, "gt60s"),
        ]
        for (seconds, tag) in cases {
            #expect(LoginElapsedBucket(seconds: seconds).rawValue == tag, "\(seconds)")
        }
    }

    @Test func elapsed는_마지막_시작부터_잰_벽시계_시간이다() {
        let clock = Clock()
        let tracker = LoginFunnelTracker(now: { clock.now })
        tracker.recordStart(.codex)
        clock.advance(5)
        #expect(tracker.abandonContext(for: .codex).elapsed == .under10s)
        clock.advance(40)   // 백그라운드에 다녀온 시간도 포함된다
        #expect(tracker.abandonContext(for: .codex).elapsed == .from10To60s)
        clock.advance(120)
        #expect(tracker.abandonContext(for: .codex).elapsed == .over60s)
        // 다시 시작하면 그 시점부터 잰다.
        tracker.recordStart(.codex)
        clock.advance(1)
        #expect(tracker.abandonContext(for: .codex).elapsed == .under10s)
    }

    @Test func attempt는_성공_이후_시작_횟수이고_3에서_멈춘다() {
        let tracker = LoginFunnelTracker()
        var attempts: [Int] = []
        for _ in 0..<5 {
            tracker.recordStart(.claude)
            attempts.append(tracker.abandonContext(for: .claude).attempt)
        }
        #expect(attempts == [1, 2, 3, 3, 3])

        tracker.recordSuccess(.claude)
        tracker.recordStart(.claude)
        #expect(tracker.abandonContext(for: .claude).attempt == 1)
    }

    @Test func attempt는_provider마다_따로_센다() {
        let tracker = LoginFunnelTracker()
        tracker.recordStart(.codex)
        tracker.recordStart(.codex)
        tracker.recordStart(.claude)
        #expect(tracker.abandonContext(for: .codex).attempt == 2)
        #expect(tracker.abandonContext(for: .claude).attempt == 1)
        // 다른 provider 성공은 영향이 없다.
        tracker.recordSuccess(.claude)
        #expect(tracker.abandonContext(for: .codex).attempt == 2)
    }

    @Test func 시작_기록이_없으면_1회_lt10s로_본다() {
        let tracker = LoginFunnelTracker()
        #expect(tracker.abandonContext(for: .grok) == .init(elapsed: .under10s, attempt: 1))
    }

    @Test func 앱_범위_추적기는_시트와_무관하게_하나다() {
        #expect(LoginFunnelTracker.shared === LoginFunnelTracker.shared)
    }

    @Test func login_abandon_파라미터는_문자열_네_개뿐이다() {
        let params = AnalyticsEvent.loginAbandon(provider: .codex, stage: .browserWait,
                                                 elapsed: .from10To60s, attempt: 7).parameters
        #expect(Set(params.keys) == ["provider", "stage", "elapsed", "attempt"])
        #expect(params["provider"] as? String == "codex")
        #expect(params["stage"] as? String == "browser_wait")
        #expect(params["elapsed"] as? String == "10_60s")
        #expect(params["attempt"] as? String == "3")   // 3 이상은 3
        #expect(params["auth_kind"] == nil)
        let low = AnalyticsEvent.loginAbandon(provider: .codex, stage: .browserWait,
                                              elapsed: .under10s, attempt: 0).parameters
        #expect(low["attempt"] as? String == "1")
        #expect(AnalyticsEvent.loginAbandon(provider: .codex, stage: .browserWait,
                                            elapsed: .under10s, attempt: 1).isProviderScoped)
    }
}
