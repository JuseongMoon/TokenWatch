//
//  AutoRefreshTests.swift
//  TokenWatchTests
//
//  Auto(적응형) 새로고침의 순수 정책 로직 검증(AutoRefreshPolicy):
//  - nextLadderIndex: 변화폭에 따른 단계 이동·히스테리시스·클램프
//  - maxUsageDelta: 창 매칭·최대 증가폭·리셋(감소) 처리·신호 없음(nil)
//  - nextResetDate: 가장 이른 미래 리셋 시각 선택
//

import Testing
import Foundation
@testable import TokenWatch

struct AutoRefreshTests {

    // MARK: 사다리 상수

    @Test func ladderIsSortedWithExpectedBounds() {
        #expect(AutoRefreshPolicy.ladder.first == 10)   // 하한: 급증 구간에서만 잠깐 내려가는 10초
        #expect(AutoRefreshPolicy.ladder.last == 300)   // 상한: 방치 시 5분
        #expect(AutoRefreshPolicy.ladder == AutoRefreshPolicy.ladder.sorted())
        #expect(AutoRefreshPolicy.ladder[AutoRefreshPolicy.baseIndex] == 60)  // 시작은 1분
    }

    // MARK: nextLadderIndex — 단계 이동

    /// ≥2%p 증가 → 한 단계 단축.
    @Test func increaseShrinksOneStep() {
        #expect(AutoRefreshPolicy.nextLadderIndex(from: 1, maxDelta: 2.0) == 0)
        #expect(AutoRefreshPolicy.nextLadderIndex(from: 3, maxDelta: 3.9) == 2)
    }

    /// ≥4%p 급증(그러나 <5) → 두 단계 단축.
    @Test func surgeShrinksTwoSteps() {
        #expect(AutoRefreshPolicy.nextLadderIndex(from: 3, maxDelta: 4.0) == 1)
        #expect(AutoRefreshPolicy.nextLadderIndex(from: 6, maxDelta: 4.5) == 4)
    }

    /// ≥5%p(중간 급증) → 여러 단계 건너뛰어 곧바로 30초로. 단 이미 더 빠르면 유지.
    @Test func moderateSurgeSkipsToThirtySeconds() {
        #expect(AutoRefreshPolicy.nextLadderIndex(from: 6, maxDelta: 5.0) == 2)   // 5분→30초
        #expect(AutoRefreshPolicy.nextLadderIndex(from: 4, maxDelta: 9.9) == 2)   // 2분→30초
        #expect(AutoRefreshPolicy.nextLadderIndex(from: 1, maxDelta: 8.0) == 1)   // 이미 20초면 유지
    }

    /// ≥10%p(폭증) → 몇 단계든 건너뛰어 곧바로 최소 간격(10초)으로.
    @Test func extremeSurgeCrashesToTenSeconds() {
        #expect(AutoRefreshPolicy.nextLadderIndex(from: 4, maxDelta: 14.0) == 0)  // 2분→10초(사용자 예시)
        #expect(AutoRefreshPolicy.nextLadderIndex(from: 6, maxDelta: 50.0) == 0)
    }

    /// ≤1%p(정체) → 한 단계 연장.
    @Test func idleGrowsOneStep() {
        #expect(AutoRefreshPolicy.nextLadderIndex(from: 1, maxDelta: 0.0) == 2)
        #expect(AutoRefreshPolicy.nextLadderIndex(from: 1, maxDelta: 1.0) == 2)
    }

    /// (1,2)%p 사이는 유지 — 목표 대역(히스테리시스).
    @Test func hysteresisBandHolds() {
        #expect(AutoRefreshPolicy.nextLadderIndex(from: 2, maxDelta: 1.01) == 2)
        #expect(AutoRefreshPolicy.nextLadderIndex(from: 2, maxDelta: 1.99) == 2)
    }

    /// 비교 신호가 없으면(nil) 현재 간격 유지 — 전부 에러여도 간격이 튀지 않는다.
    @Test func noSignalHolds() {
        #expect(AutoRefreshPolicy.nextLadderIndex(from: 0, maxDelta: nil) == 0)
        #expect(AutoRefreshPolicy.nextLadderIndex(from: 4, maxDelta: nil) == 4)
    }

    /// 사다리 양 끝에서 클램프된다(두 단계 단축·폭증 포함).
    @Test func clampsAtFastestAndSlowest() {
        #expect(AutoRefreshPolicy.nextLadderIndex(from: 0, maxDelta: 25.0) == 0)  // 이미 최소면 폭증에도 유지
        #expect(AutoRefreshPolicy.nextLadderIndex(from: 1, maxDelta: 4.0) == 0)   // -2 → 클램프 0
        let last = AutoRefreshPolicy.ladder.count - 1
        #expect(AutoRefreshPolicy.nextLadderIndex(from: last, maxDelta: 0.0) == last)
    }

    // MARK: maxUsageDelta — 변화폭 계산

    /// 여러 창 중 가장 큰 증가폭을 고른다.
    @Test func picksLargestIncreaseAcrossWindows() {
        let old = ["a|session": 10.0, "a|week": 50.0]
        let new = ["a|session": 13.5, "a|week": 50.2]
        #expect(AutoRefreshPolicy.maxUsageDelta(from: old, to: new) == 3.5)
    }

    /// 리셋으로 감소한 창은 0으로 취급한다(음수 delta로 간격이 요동치지 않게).
    @Test func resetDropCountsAsZero() {
        #expect(AutoRefreshPolicy.maxUsageDelta(from: ["a|s": 90.0], to: ["a|s": 2.0]) == 0)
    }

    /// 세션 리셋(감소)과 주간 증가가 섞이면 증가 쪽을 취한다.
    @Test func mixedResetAndIncreaseTakesIncrease() {
        let old = ["a|session": 95.0, "a|week": 40.0]
        let new = ["a|session": 1.0, "a|week": 41.6]
        let delta = AutoRefreshPolicy.maxUsageDelta(from: old, to: new)
        #expect(delta != nil && abs(delta! - 1.6) < 0.0001)
    }

    /// 겹치는 창이 없으면 nil(신호 없음) — 새 에이전트 추가 직후 등.
    @Test func disjointKeysGiveNoSignal() {
        #expect(AutoRefreshPolicy.maxUsageDelta(from: ["a|s": 10.0], to: ["b|s": 20.0]) == nil)
        #expect(AutoRefreshPolicy.maxUsageDelta(from: [:], to: [:]) == nil)
    }

    // MARK: nextResetDate — 리셋 시각 선택

    private func snap(_ windows: [UsageWindow]) -> AgentSnapshot {
        AgentSnapshot(windows: windows, planLabel: nil, fetchedAt: .now, error: nil)
    }

    private func win(_ label: String, resetsAt: Date?) -> UsageWindow {
        UsageWindow(label: label, usedPercent: 10, resetsAt: resetsAt, kind: .session)
    }

    /// 여러 에이전트·여러 창 중 가장 이른 미래 리셋을 고른다.
    @Test func earliestFutureResetWins() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshots = [
            snap([win("session", resetsAt: now.addingTimeInterval(3_600)),
                  win("week", resetsAt: now.addingTimeInterval(120))]),
            snap([win("other", resetsAt: now.addingTimeInterval(900))]),
        ]
        #expect(AutoRefreshPolicy.nextResetDate(in: snapshots, after: now)
                == now.addingTimeInterval(120))
    }

    /// 이미 지난 리셋과 resetsAt 없는 창은 무시한다.
    @Test func pastAndNilResetsAreIgnored() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshots = [
            snap([win("past", resetsAt: now.addingTimeInterval(-5)),
                  win("none", resetsAt: nil)]),
        ]
        #expect(AutoRefreshPolicy.nextResetDate(in: snapshots, after: now) == nil)
    }

    /// 정확히 now인 리셋은 미래가 아니다 — 발화 직후 같은 시각으로 다시 예약되는 루프 방지.
    @Test func resetExactlyAtNowIsNotFuture() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshots = [snap([win("edge", resetsAt: now)])]
        #expect(AutoRefreshPolicy.nextResetDate(in: snapshots, after: now) == nil)
    }
}
