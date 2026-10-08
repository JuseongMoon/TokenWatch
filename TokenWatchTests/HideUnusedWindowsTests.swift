//
//  HideUnusedWindowsTests.swift
//  TokenWatchTests
//
//  "hide unused graphs" 설정(퍼센테이지 / 충전식)의 판정 기준
//  (UsageWindow.isUnused / isUnusedCredit)과 UnusedWindowFilter 필터 결과를 순수 로직으로 검증한다.
//

import Testing
import Foundation
@testable import TokenWatch

struct HideUnusedWindowsTests {

    // MARK: 표본 창

    private static let unusedGauge = UsageWindow(label: "Current session", usedPercent: 0,
                                                 resetsAt: nil, kind: .session)
    private static let usedGauge = UsageWindow(label: "Current week (all models)", usedPercent: 42,
                                               resetsAt: nil, kind: .weekly)
    /// 월 한도 $40 중 $0 사용한 Extra usage(승격 후 모양).
    private static let unusedCredit = UsageWindow(label: "Extra usage", usedPercent: 0, resetsAt: nil,
                                                  kind: .weekly, style: .creditGauge,
                                                  valueText: "$40.00 left",
                                                  balanceRemaining: 40, balanceTotal: 40)
    /// 월 한도 $40 중 $10 사용.
    private static let usedCredit = UsageWindow(label: "Credits", usedPercent: 25, resetsAt: nil,
                                                kind: .weekly, style: .creditGauge,
                                                valueText: "$30.00 left",
                                                balanceRemaining: 30, balanceTotal: 40)
    private static let balanceText = UsageWindow(label: "Balance", usedPercent: 0, resetsAt: nil,
                                                 kind: .weekly, style: .balance,
                                                 valueText: "6.50 USD left")

    private static let mixed = [unusedGauge, usedGauge, unusedCredit, usedCredit, balanceText]

    // MARK: isUnused 판정 (퍼센테이지)

    @Test func gaugeAtZeroIsUnused() {
        #expect(Self.unusedGauge.isUnused)
    }

    @Test func gaugeAboveZeroIsUsed() {
        // 조금이라도 쓴 창(0.4%)은 "전혀 쓰지 않음"이 아니므로 숨기지 않는다.
        let w = UsageWindow(label: "Current session", usedPercent: 0.4,
                            resetsAt: nil, kind: .session)
        #expect(w.isUnused == false)
    }

    @Test func balanceAtZeroIsNeverUnused() {
        // 잔액(선불 크레딧) 스타일은 usedPercent가 0이어도 "그래프 0%"가 아니므로 숨기지 않는다.
        #expect(Self.balanceText.isUnused == false)
    }

    @Test func creditGaugeIsNotPercentUnused() {
        // 충전형은 퍼센테이지 판정 대상이 아니다(별도 isUnusedCredit).
        #expect(Self.unusedCredit.isUnused == false)
    }

    // MARK: isUnusedCredit 판정 (충전식)

    @Test func creditGaugeNeverSpentIsUnusedCredit() {
        #expect(Self.unusedCredit.isUnusedCredit)
    }

    @Test func creditGaugeWithOneCentSpentIsUsed() {
        // $40 한도에서 $0.01만 써도(0.025%) 미사용이 아니다.
        let used = CreditGaugePolicy.usedPercent(remaining: 39.99, total: 40) ?? 0
        let w = UsageWindow(label: "Extra usage", usedPercent: used, resetsAt: nil, kind: .weekly,
                            style: .creditGauge, valueText: "$39.99 left",
                            balanceRemaining: 39.99, balanceTotal: 40)
        #expect(used > 0)
        #expect(w.isUnusedCredit == false)
    }

    @Test func estimatedCreditGaugeIsNeverUnusedCredit() {
        // 총액이 관측 최고 잔액 추정치면 "가득 = 미사용"이 아니므로 판정하지 않는다.
        let w = UsageWindow(label: "Balance", usedPercent: 0, resetsAt: nil, kind: .weekly,
                            style: .creditGauge, valueText: "94.20 CNY",
                            balanceRemaining: 94.2, estimatedTotal: true)
        #expect(w.isUnusedCredit == false)
    }

    @Test func balanceTextIsNeverUnusedCredit() {
        #expect(Self.balanceText.isUnusedCredit == false)
    }

    @Test func subscriptionGaugeIsNeverUnusedCredit() {
        #expect(Self.unusedGauge.isUnusedCredit == false)
    }

    // MARK: Claude extra_usage → 승격 경로

    @Test func claudeExtraUsageNeverSpentIsUnusedCreditAfterPromotion() throws {
        // 한도 $40, 사용 0¢ → mapper는 .balance, AgentStore가 같은 정책으로 .creditGauge 승격.
        let data = Data(#"{"extra_usage": {"is_enabled": true, "monthly_limit": 4000, "used_credits": 0, "currency": "USD"}}"#.utf8)
        let resp = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        let balance = try #require(ClaudeUsageMapper.windows(from: resp).first)
        let remaining = try #require(balance.balanceRemaining)
        let total = try #require(balance.balanceTotal)
        let used = try #require(CreditGaugePolicy.usedPercent(remaining: remaining, total: total))
        let promoted = balance.promotedToCreditGauge(usedPercent: used, estimatedTotal: false)
        #expect(promoted.isUnusedCredit)
    }

    // MARK: UnusedWindowFilter 조합

    @Test func filterBothOffKeepsEverything() {
        let visible = UnusedWindowFilter.visible(Self.mixed, hidePercent: false, hideCredit: false)
        #expect(visible.map(\.label) == Self.mixed.map(\.label))
    }

    @Test func filterPercentOnlyRemovesUnusedGauges() {
        let visible = UnusedWindowFilter.visible(Self.mixed, hidePercent: true, hideCredit: false)
        #expect(visible.map(\.label) == ["Current week (all models)", "Extra usage", "Credits", "Balance"])
    }

    @Test func filterCreditOnlyRemovesUnusedCredits() {
        let visible = UnusedWindowFilter.visible(Self.mixed, hidePercent: false, hideCredit: true)
        #expect(visible.map(\.label) == ["Current session", "Current week (all models)", "Credits", "Balance"])
    }

    @Test func filterBothOnRemovesBoth() {
        let visible = UnusedWindowFilter.visible(Self.mixed, hidePercent: true, hideCredit: true)
        #expect(visible.map(\.label) == ["Current week (all models)", "Credits", "Balance"])
    }

    @Test func filterKeepsAllWhenNoneUnused() {
        let windows = [
            UsageWindow(label: "Current session", usedPercent: 12, resetsAt: nil, kind: .session),
            Self.usedGauge, Self.usedCredit,
        ]
        let visible = UnusedWindowFilter.visible(windows, hidePercent: true, hideCredit: true)
        #expect(visible.count == 3)
    }

    @Test func filterCanEmptyAllWindows() {
        // 모든 창이 미사용이면 필터 결과가 비어 안내 문구를 띄우는 경로로 들어간다.
        let windows = [Self.unusedGauge,
                       UsageWindow(label: "Current week (all models)", usedPercent: 0, resetsAt: nil, kind: .weekly),
                       Self.unusedCredit]
        let visible = UnusedWindowFilter.visible(windows, hidePercent: true, hideCredit: true)
        #expect(visible.isEmpty)
    }
}
