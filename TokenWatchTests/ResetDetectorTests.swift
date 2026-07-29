//
//  ResetDetectorTests.swift
//  TokenWatchTests
//
//  리셋 감지/예약의 순수 정책 로직 검증:
//  - ResetDetector.detect: 첫 관측 baseline(오탐 방지)·resetsAt 전진·정시 억제·급감 보조 신호·묶음
//  - ResetSchedulePolicy: 적격 필터·분버킷 병합·caps·reconcile diff
//

import Testing
import Foundation
@testable import TokenWatch

struct ResetDetectorTests {
    let now = Date(timeIntervalSince1970: 2_000_000)

    private func obs(_ resetsAt: Date?, _ used: Double) -> WindowObservation {
        WindowObservation(resetsAt: resetsAt, usedPercent: used)
    }
    /// 창 주기를 명시한 관측 — 주 신호의 최소 전진 폭이 걸리는지 보는 테스트용.
    private func obs(_ resetsAt: Date?, _ used: Double, window: TimeInterval) -> WindowObservation {
        WindowObservation(resetsAt: resetsAt, usedPercent: used, windowSeconds: window)
    }
    private func kindOf(_ key: String) -> WindowKind { key.contains("week") ? .weekly : .session }

    private let week: TimeInterval = 604_800
    private let session: TimeInterval = 18_000

    // MARK: detect

    /// 직전 관측이 없으면(첫 fetch·새 창) 이벤트 없이 baseline만 기록한다 — 처음 추가 시 무알림.
    @Test func firstObservationRecordsBaselineOnly() {
        let cur = ["a|session": obs(now.addingTimeInterval(3600), 5)]
        let (events, baseline) = ResetDetector.detect(previous: [:], current: cur, now: now, kindOf: kindOf)
        #expect(events.isEmpty)
        #expect(baseline == cur)
    }

    /// resetsAt 전진 + 예정보다 이른 리셋(now < 직전 resetsAt−skew) → 서프라이즈 이벤트 발화.
    @Test func earlyResetFiresEvent() {
        let prev = ["a|session": obs(now.addingTimeInterval(3600), 80)]   // 리셋 예정 1시간 뒤
        let cur = ["a|session": obs(now.addingTimeInterval(3600 + 18000), 2)]   // resetsAt 전진 + 사용률 급감
        let (events, _) = ResetDetector.detect(previous: prev, current: cur, now: now, kindOf: kindOf)
        #expect(events.count == 1)
        #expect(events.first?.labels == ["session"])
        #expect(events.first?.kinds == [.session])
    }

    /// resetsAt 전진 + 정시(now >= 직전 resetsAt−skew) → 예약형이 소유하므로 억제.
    @Test func onTimeResetIsSuppressed() {
        let prev = ["a|session": obs(now.addingTimeInterval(-10), 80)]   // 방금 리셋 예정 시각 지남
        let cur = ["a|session": obs(now.addingTimeInterval(18000), 2)]
        let (events, _) = ResetDetector.detect(previous: prev, current: cur, now: now, kindOf: kindOf)
        #expect(events.isEmpty)
    }

    /// resetsAt 불변(미래) + 사용률 대폭 급감 → 보조 신호로 발화.
    @Test func dropWithoutResetAdvanceFires() {
        let r = now.addingTimeInterval(3600)
        let (events, _) = ResetDetector.detect(previous: ["a|session": obs(r, 90)],
                                               current: ["a|session": obs(r, 3)],
                                               now: now, kindOf: kindOf)
        #expect(events.count == 1)
    }

    /// 소폭 감소(임계 미만)는 리셋으로 보지 않는다.
    @Test func smallDropDoesNotFire() {
        let r = now.addingTimeInterval(3600)
        let (events, _) = ResetDetector.detect(previous: ["a|session": obs(r, 50)],
                                               current: ["a|session": obs(r, 40)],
                                               now: now, kindOf: kindOf)
        #expect(events.isEmpty)
    }

    /// 급감했어도 높은 값으로 착지하면(>5%) 리셋이 아니다.
    @Test func dropButHighLandingDoesNotFire() {
        let r = now.addingTimeInterval(3600)
        let (events, _) = ResetDetector.detect(previous: ["a|session": obs(r, 90)],
                                               current: ["a|session": obs(r, 30)],
                                               now: now, kindOf: kindOf)
        #expect(events.isEmpty)
    }

    /// resetsAt이 없는 창은 보조 신호(급감)로만 감지하고 fireTime은 now.
    @Test func nilResetsAtUsesSecondarySignal() {
        let (events, _) = ResetDetector.detect(previous: ["a|session": obs(nil, 85)],
                                               current: ["a|session": obs(nil, 1)],
                                               now: now, kindOf: kindOf)
        #expect(events.count == 1)
        #expect(events.first?.fireTime == now)
    }

    /// 창이 사라지면 이벤트 없이 baseline에서도 빠진다(오염 방지).
    @Test func vanishedWindowNoEvent() {
        let prev = ["a|session": obs(now.addingTimeInterval(-10), 80),
                    "a|week": obs(now.addingTimeInterval(3600), 50)]
        let cur = ["a|week": obs(now.addingTimeInterval(3600), 51)]
        let (events, baseline) = ResetDetector.detect(previous: prev, current: cur, now: now, kindOf: kindOf)
        #expect(events.isEmpty)
        #expect(baseline["a|session"] == nil)
    }

    /// 한 에이전트에서 동시에 여러 창이 서프라이즈 리셋되면 이벤트 1개로 묶인다(에이전트별 묶음).
    @Test func multipleWindowsMergeIntoOneEvent() {
        let fa = now.addingTimeInterval(3600), fb = now.addingTimeInterval(7200)
        let prev = ["a|session": obs(fa, 80), "a|week (Opus)": obs(fb, 70)]
        let cur = ["a|session": obs(fa.addingTimeInterval(18000), 1),
                   "a|week (Opus)": obs(fb.addingTimeInterval(604800), 2)]
        let (events, _) = ResetDetector.detect(previous: prev, current: cur, now: now, kindOf: kindOf)
        #expect(events.count == 1)
        #expect(events.first?.kinds == [.session, .weekly])
        #expect(events.first?.labels.count == 2)
    }

    // MARK: 주 신호 조이기 회귀 — resetsAt 전진 단독은 리셋이 아니다

    /// **핵심 회귀(알림 폭주 재현)**: 사용률 0%인 창의 resetsAt이 폴링 간격만큼 미끄러져도
    /// 리셋이 아니다. 서버가 미사용 창의 reset_at을 `now + 주기`로 매번 다시 계산해 주면
    /// resetsAt이 벽시계와 1:1로 전진하는데, 이걸 리셋으로 보면 새로고침마다 알림이 나간다.
    @Test func slidingResetOnUnusedWindowIsNotAReset() {
        let r = now.addingTimeInterval(week)
        for slide in [1.0, 60.0, 300.0] as [TimeInterval] {
            #expect(ResetDetector.resetBoundary(previous: obs(r, 0, window: week),
                                                current: obs(r + slide, 0, window: week),
                                                now: now) == nil)
        }
        // 전진 폭이 임계를 넘겨도(앱을 오래 꺼뒀다 켠 경우) 0%→0%면 여전히 리셋이 아니다.
        #expect(ResetDetector.resetBoundary(previous: obs(r, 0, window: week),
                                            current: obs(r + week, 0, window: week),
                                            now: now) == nil)
    }

    /// detect 수준 재현: 미끄러지는 미사용 주간 창은 이벤트를 내지 않고 baseline만 갱신한다.
    @Test func slidingUnusedWindowProducesNoEvent() {
        let r = now.addingTimeInterval(week)
        let prev = ["a|week (spark)": obs(r, 0, window: week)]
        let cur = ["a|week (spark)": obs(r.addingTimeInterval(60), 0, window: week)]
        let (events, baseline) = ResetDetector.detect(previous: prev, current: cur, now: now, kindOf: kindOf)
        #expect(events.isEmpty)
        #expect(baseline == cur)
    }

    /// 사용 중인 창의 초 단위 지터도 리셋이 아니다(최소 전진 폭에 걸린다).
    @Test func secondScaleJitterIsNotAReset() {
        let r = now.addingTimeInterval(week)
        #expect(ResetDetector.resetBoundary(previous: obs(r, 40, window: week),
                                            current: obs(r.addingTimeInterval(1), 40, window: week),
                                            now: now) == nil)
    }

    /// 사용률이 오히려 늘었는데 resetsAt만 한 주기 전진 → 리셋 아님(창 재앵커).
    @Test func advanceWithoutUsageDropIsNotAReset() {
        let r = now.addingTimeInterval(week)
        #expect(ResetDetector.resetBoundary(previous: obs(r, 40, window: week),
                                            current: obs(r + week, 45, window: week),
                                            now: now) == nil)
    }

    // MARK: 주 신호가 지켜야 할 진짜 리셋 (급감 조건만으론 못 잡는 대역)

    /// 적게 쓴 창의 이른 리셋: 12%→0%는 급감 임계(20%p)에 못 미쳐 보조 신호로는 안 잡힌다.
    /// 주 신호가 살아 있어야 알림이 나간다.
    @Test func lowUsageEarlyResetStillFires() {
        let r = now.addingTimeInterval(3600)
        #expect(ResetDetector.resetBoundary(previous: obs(r, 12, window: week),
                                            current: obs(r + week, 0, window: week),
                                            now: now) == r)
    }

    /// 이른 리셋 직후 곧바로 사용해 착지가 높은 경우(70%→25%): 착지 천장(5%)을 넘어
    /// 보조 신호로는 안 잡힌다. 주 신호가 잡아야 한다.
    @Test func earlyResetFollowedByImmediateUseStillFires() {
        let r = now.addingTimeInterval(3600)
        #expect(ResetDetector.resetBoundary(previous: obs(r, 70, window: session),
                                            current: obs(r + session, 25, window: session),
                                            now: now) == r)
    }

    /// resetBoundary: 전진→직전 resetsAt, nil+급감→now, 변화없음→nil.
    @Test func resetBoundaryPrimaryAndSecondary() {
        let r1 = now.addingTimeInterval(100), r2 = now.addingTimeInterval(200)
        #expect(ResetDetector.resetBoundary(previous: obs(r1, 50), current: obs(r2, 5), now: now) == r1)
        #expect(ResetDetector.resetBoundary(previous: obs(nil, 90), current: obs(nil, 2), now: now) == now)
        #expect(ResetDetector.resetBoundary(previous: obs(r1, 50), current: obs(r1, 52), now: now) == nil)
    }
}

struct ResetSchedulePolicyTests {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let agentA = UUID()

    private func gauge(_ label: String, _ kind: WindowKind, resetsAt: Date?,
                       style: UsageStyle = .gauge) -> UsageWindow {
        UsageWindow(label: label, usedPercent: 50, resetsAt: resetsAt, kind: kind, style: style)
    }

    /// identifier는 같은 분 안에서는 안정적이고 다음 분이면 달라진다(초 흔들림 흡수).
    @Test func identifierIsStableWithinMinute() {
        let t1 = Date(timeIntervalSince1970: 2_000_040)   // 분 경계(33334분 00초)
        let t2 = Date(timeIntervalSince1970: 2_000_099)   // 같은 분(33334분 59초)
        let t3 = Date(timeIntervalSince1970: 2_000_100)   // 다음 분(33335분 00초)
        #expect(ResetSchedulePolicy.identifier(agentID: agentA, fireTime: t1)
                == ResetSchedulePolicy.identifier(agentID: agentA, fireTime: t2))
        #expect(ResetSchedulePolicy.identifier(agentID: agentA, fireTime: t1)
                != ResetSchedulePolicy.identifier(agentID: agentA, fireTime: t3))
    }

    /// 적격 창만 남긴다: .gauge + 미래 resetsAt. 충전형(.creditGauge/.balance)·과거·nil은 제외.
    @Test func targetsFilterEligible() {
        let future = now.addingTimeInterval(3600), past = now.addingTimeInterval(-10)
        let windows = [
            gauge("session", .session, resetsAt: future),
            gauge("week", .weekly, resetsAt: future),
            gauge("credit", .weekly, resetsAt: future, style: .creditGauge),
            gauge("bal", .weekly, resetsAt: future, style: .balance),
            gauge("past", .session, resetsAt: past),
            gauge("nore", .session, resetsAt: nil),
        ]
        let t = ResetSchedulePolicy.targets(agentID: agentA, windows: windows, now: now,
                                            sessionOn: true, weeklyOn: true)
        #expect(t.flatMap(\.labels).sorted() == ["session", "week"])
    }

    /// 세션/주간 토글을 존중한다.
    @Test func targetsRespectToggles() {
        let future = now.addingTimeInterval(3600)
        let windows = [gauge("session", .session, resetsAt: future),
                       gauge("week", .weekly, resetsAt: future)]
        let sessOnly = ResetSchedulePolicy.targets(agentID: agentA, windows: windows, now: now,
                                                   sessionOn: true, weeklyOn: false)
        #expect(sessOnly.flatMap(\.labels) == ["session"])
        let weekOnly = ResetSchedulePolicy.targets(agentID: agentA, windows: windows, now: now,
                                                   sessionOn: false, weeklyOn: true)
        #expect(weekOnly.flatMap(\.labels) == ["week"])
    }

    /// 같은 분 버킷의 창들은 하나의 목표로 병합된다.
    @Test func sameBucketMerges() {
        let r = now.addingTimeInterval(3600)
        let windows = [gauge("weekAll", .weekly, resetsAt: r),
                       gauge("weekOpus", .weekly, resetsAt: r.addingTimeInterval(30))]
        let t = ResetSchedulePolicy.targets(agentID: agentA, windows: windows, now: now,
                                            sessionOn: true, weeklyOn: true)
        #expect(t.count == 1)
        #expect(t.first?.labels.count == 2)
    }

    /// 에이전트당 가장 이른 perAgentLimit개만 남긴다.
    @Test func perAgentLimitCaps() {
        let windows = (0..<10).map { i in
            gauge("w\(i)", .weekly, resetsAt: now.addingTimeInterval(Double(i + 1) * 3600))
        }
        let t = ResetSchedulePolicy.targets(agentID: agentA, windows: windows, now: now,
                                            sessionOn: true, weeklyOn: true)
        #expect(t.count == ResetSchedulePolicy.perAgentLimit)
    }

    /// 전역 상한으로 자르되 가장 이른 것부터 유지한다.
    @Test func clampGlobalKeepsEarliest() {
        let targets = (0..<40).map { i in
            ScheduleTarget(agentID: agentA, fireTime: now.addingTimeInterval(Double(i) * 60),
                           kinds: [.session], labels: ["s"])
        }
        let clamped = ResetSchedulePolicy.clampGlobal(targets)
        #expect(clamped.count == ResetSchedulePolicy.globalLimit)
        #expect(clamped.first?.fireTime == now)
    }

    /// reconcile: desired에 없는 우리 소유(reset|) pending은 제거, 새 것은 add, 남의 것은 보존.
    @Test func reconcileAddsAndRemoves() {
        let desired: Set<String> = ["reset|X|100", "reset|X|200"]
        let pending = ["reset|X|100", "reset|X|999", "other|keep"]
        let (add, remove) = ResetSchedulePolicy.reconcile(desired: desired, pending: pending)
        #expect(add == ["reset|X|200"])
        #expect(remove == ["reset|X|999"])
    }

    /// 감지형 identifier는 예약형 네임스페이스 밖에 있어야 한다 — reconcile이 자기 접두어
    /// pending을 desired에 없다는 이유로 지우므로, 접두어를 공유하면 방금 발화한 알림이
    /// 제거 대상이 된다.
    @Test func firedIDsAreOutsideScheduleNamespace() {
        #expect(!ResetDetector.firedIDPrefix.hasPrefix(ResetSchedulePolicy.idPrefix))
        let firedID = "\(ResetDetector.firedIDPrefix)\(agentA.uuidString)|100"
        let (_, remove) = ResetSchedulePolicy.reconcile(desired: [], pending: [firedID])
        #expect(remove.isEmpty)
    }
}
