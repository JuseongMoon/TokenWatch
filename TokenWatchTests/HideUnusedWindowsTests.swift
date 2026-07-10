//
//  HideUnusedWindowsTests.swift
//  TokenWatchTests
//
//  "미사용(0%) 창 숨김" 설정의 판정 기준(UsageWindow.isUnused)과
//  그에 따른 필터 결과를 순수 로직으로 검증한다.
//

import Testing
import Foundation
@testable import TokenWatch

struct HideUnusedWindowsTests {

    // MARK: isUnused 판정

    @Test func gaugeAtZeroIsUnused() {
        let w = UsageWindow(label: "Current session", usedPercent: 0,
                            resetsAt: nil, kind: .session)
        #expect(w.isUnused)
    }

    @Test func gaugeAboveZeroIsUsed() {
        // 조금이라도 쓴 창(0.4%)은 "전혀 쓰지 않음"이 아니므로 숨기지 않는다.
        let w = UsageWindow(label: "Current session", usedPercent: 0.4,
                            resetsAt: nil, kind: .session)
        #expect(w.isUnused == false)
    }

    @Test func balanceAtZeroIsNeverUnused() {
        // 잔액(선불 크레딧) 스타일은 usedPercent가 0이어도 "그래프 0%"가 아니므로 숨기지 않는다.
        let w = UsageWindow(label: "Credits", usedPercent: 0, resetsAt: nil,
                            kind: .weekly, style: .balance, valueText: "6.50 USD left")
        #expect(w.isUnused == false)
    }

    // MARK: 필터 결과 (뷰의 visibleWindows와 동일한 표현식)

    @Test func filterRemovesOnlyUnusedGauges() {
        let windows = [
            UsageWindow(label: "Current session", usedPercent: 0, resetsAt: nil, kind: .session),
            UsageWindow(label: "Current week (all models)", usedPercent: 42, resetsAt: nil, kind: .weekly),
            UsageWindow(label: "Current week (Fable)", usedPercent: 0, resetsAt: nil, kind: .weekly),
            UsageWindow(label: "Credits", usedPercent: 0, resetsAt: nil, kind: .weekly,
                        style: .balance, valueText: "6.50 USD left"),
        ]
        let visible = windows.filter { !$0.isUnused }
        // 사용 중 게이지 + 잔액만 남고, 0% 게이지 두 개는 제거된다.
        #expect(visible.map(\.label) == ["Current week (all models)", "Credits"])
    }

    @Test func filterKeepsAllWhenNoneUnused() {
        let windows = [
            UsageWindow(label: "Current session", usedPercent: 12, resetsAt: nil, kind: .session),
            UsageWindow(label: "Current week (all models)", usedPercent: 88, resetsAt: nil, kind: .weekly),
        ]
        let visible = windows.filter { !$0.isUnused }
        #expect(visible.count == 2)
    }

    @Test func filterCanEmptyAllWindows() {
        // 모든 게이지가 0%면 필터 결과가 비어 안내 문구를 띄우는 경로로 들어간다.
        let windows = [
            UsageWindow(label: "Current session", usedPercent: 0, resetsAt: nil, kind: .session),
            UsageWindow(label: "Current week (all models)", usedPercent: 0, resetsAt: nil, kind: .weekly),
        ]
        let visible = windows.filter { !$0.isUnused }
        #expect(visible.isEmpty)
    }
}
