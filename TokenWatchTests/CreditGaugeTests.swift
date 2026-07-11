//
//  CreditGaugeTests.swift
//  TokenWatchTests
//
//  충전형(선불 크레딧) 게이지화의 순수 로직 검증:
//  peak 추정·소비율 환산·게이지 채움 방향 반전·창 스타일 불변식.
//  (부동소수점 == 비교가 안전하도록 2의 거듭제곱 분수 값만 쓴다.)
//

import Testing
import Foundation
@testable import TokenWatch

struct CreditGaugeTests {

    // MARK: 소비율 환산 (CreditGaugePolicy.usedPercent)

    @Test func usedPercentFullBalanceIsZero() {
        #expect(CreditGaugePolicy.usedPercent(remaining: 500, total: 500) == 0)
    }

    @Test func usedPercentHalfBalanceIsFifty() {
        #expect(CreditGaugePolicy.usedPercent(remaining: 250, total: 500) == 50)
    }

    @Test func usedPercentQuarterSpent() {
        // 375 / 500 남음 → 25% used.
        #expect(CreditGaugePolicy.usedPercent(remaining: 375, total: 500) == 25)
    }

    @Test func usedPercentDepletedIsHundred() {
        #expect(CreditGaugePolicy.usedPercent(remaining: 0, total: 500) == 100)
    }

    @Test func usedPercentOverspendClampsToHundred() {
        // 잔액이 음수(초과지출/환불대기)여도 100%로 clamp.
        #expect(CreditGaugePolicy.usedPercent(remaining: -10, total: 500) == 100)
    }

    @Test func usedPercentNilWhenNoTotal() {
        // 총액을 모르면(0/음수) nil → balance 텍스트 fallback.
        #expect(CreditGaugePolicy.usedPercent(remaining: 100, total: 0) == nil)
        #expect(CreditGaugePolicy.usedPercent(remaining: 100, total: -5) == nil)
    }

    // MARK: peak 추정 (CreditGaugePolicy.newPeak)

    @Test func newPeakFromNilIsObserved() {
        #expect(CreditGaugePolicy.newPeak(nil, observed: 42) == 42)
    }

    @Test func newPeakIsMonotonic() {
        // 잔액이 줄어도 peak는 유지(최고값).
        #expect(CreditGaugePolicy.newPeak(500, observed: 300) == 500)
    }

    @Test func newPeakGrowsOnTopUp() {
        // 추가 충전 → 잔액이 이전 peak를 넘으면 peak 갱신(그 순간 게이지 100%로 리셋).
        #expect(CreditGaugePolicy.newPeak(500, observed: 900) == 900)
        #expect(CreditGaugePolicy.usedPercent(remaining: 900, total: 900) == 0)
    }

    // MARK: 게이지 채움 방향 (TerminalGauge.fillFraction)

    @Test func fillFractionSubscriptionUsesUsed() {
        // 구독형: 채움 = 사용량.
        #expect(TerminalGauge.fillFraction(used: 0.25, fillsRemaining: false) == 0.25)
    }

    @Test func fillFractionCreditFillsRemaining() {
        // 충전형: 채움 = 남은 잔액 = 1 - 사용량 (역방향).
        #expect(TerminalGauge.fillFraction(used: 0.25, fillsRemaining: true) == 0.75)
    }

    @Test func fillFractionClamps() {
        #expect(TerminalGauge.fillFraction(used: 1.5, fillsRemaining: false) == 1)
        #expect(TerminalGauge.fillFraction(used: -0.5, fillsRemaining: true) == 1)   // 1 - 0
    }

    // MARK: 창 스타일 불변식

    @Test func creditGaugeIsGaugeLikeButNotUnused() {
        // 잔액 가득(used 0%)이어도 충전형 게이지는 미사용이 아니다(hide unused에 안 걸림).
        let w = UsageWindow(label: "Credits", usedPercent: 0, resetsAt: nil, kind: .weekly,
                            style: .creditGauge, valueText: "500 credits",
                            balanceRemaining: 500, balanceTotal: 500)
        #expect(w.isGaugeLike)
        #expect(w.isUnused == false)
    }

    @Test func subscriptionGaugeIsGaugeLike() {
        let w = UsageWindow(label: "Session", usedPercent: 40, resetsAt: nil, kind: .session)
        #expect(w.isGaugeLike)
    }

    @Test func balanceIsNotGaugeLike() {
        let w = UsageWindow(label: "Credits", usedPercent: 0, resetsAt: nil, kind: .weekly,
                            style: .balance, valueText: "6.50 USD")
        #expect(w.isGaugeLike == false)
        #expect(w.isUnused == false)
    }

    @Test func unusedSubscriptionGaugeIsUnused() {
        // 구독형 게이지만 0% used면 미사용으로 판정(hide unused 대상).
        let w = UsageWindow(label: "Weekly", usedPercent: 0, resetsAt: nil, kind: .weekly)
        #expect(w.isUnused)
    }

    // MARK: 승격 (promotedToCreditGauge)

    @Test func promotionPreservesValueAndSetsStyle() {
        let balance = UsageWindow(label: "Credits", usedPercent: 0, resetsAt: nil, kind: .weekly,
                                  style: .balance, valueText: "487.50 credits left",
                                  balanceRemaining: 487.5, balanceTotal: 500)
        let promoted = balance.promotedToCreditGauge(usedPercent: 2.5, estimatedTotal: false)
        #expect(promoted.style == .creditGauge)
        #expect(promoted.usedPercent == 2.5)
        #expect(promoted.estimatedTotal == false)
        #expect(promoted.valueText == "487.50 credits left")   // 텍스트 보존
        #expect(promoted.balanceRemaining == 487.5)            // raw 잔액 보존
        #expect(promoted.remainingPercent == 97.5)
    }

    @Test func estimatedPromotionFlagsApprox() {
        let balance = UsageWindow(label: "Balance", usedPercent: 0, resetsAt: nil, kind: .weekly,
                                  style: .balance, valueText: "94.20 CNY", balanceRemaining: 94.2)
        let promoted = balance.promotedToCreditGauge(usedPercent: 0, estimatedTotal: true)
        #expect(promoted.estimatedTotal)
    }

    // MARK: Claude 추가 크레딧(extra_usage) 매핑
    // mapper 단계에선 balanceTotal을 실은 .balance 창까지 만든다.
    // (AgentStore.promoteCreditWindows가 이후 .creditGauge로 승격 — 그건 MainActor 로직.)

    private func mapExtra(_ extraJSON: String) throws -> [UsageWindow] {
        let data = Data("{\"extra_usage\": \(extraJSON)}".utf8)
        let resp = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        return ClaudeUsageMapper.windows(from: resp)
    }

    @Test func extraUsageEnabledBecomesBalanceWindow() throws {
        // 월 한도 $40(4000¢) 중 $15(1500¢) 사용 → 남은 $25.
        let windows = try mapExtra(
            #"{"is_enabled": true, "monthly_limit": 4000, "used_credits": 1500, "currency": "USD"}"#)
        #expect(windows.count == 1)
        let w = try #require(windows.first)
        #expect(w.label == "Extra usage")
        #expect(w.style == .balance)
        #expect(w.balanceRemaining == 25)
        #expect(w.balanceTotal == 40)
        #expect(w.valueText == "$25.00 left")
    }

    @Test func extraUsageDisabledYieldsNoWindow() throws {
        let windows = try mapExtra(
            #"{"is_enabled": false, "monthly_limit": 4000, "used_credits": 1500}"#)
        #expect(windows.isEmpty)
    }

    @Test func extraUsageMissingLimitYieldsNoWindow() throws {
        let windows = try mapExtra(#"{"is_enabled": true, "used_credits": 1500}"#)
        #expect(windows.isEmpty)
    }

    @Test func extraUsageNonUSDFormatsCurrencyCode() throws {
        // 5000-1000 = 4000¢ = 40.00, 비USD는 코드 접미.
        let windows = try mapExtra(
            #"{"is_enabled": true, "monthly_limit": 5000, "used_credits": 1000, "currency": "EUR"}"#)
        #expect(windows.first?.valueText == "40.00 EUR left")
    }

    @Test func extraUsageBackfillsUsedFromUtilization() throws {
        // used_credits 없이 utilization(25%)만 → 한도×사용률로 역산. 4000¢, 25% → 남은 $30.
        let windows = try mapExtra(
            #"{"is_enabled": true, "monthly_limit": 4000, "utilization": 25}"#)
        #expect(windows.first?.balanceRemaining == 30)
    }

    @Test func extraUsageAppendsAfterSubscriptionWindows() throws {
        // 구독 창(limits) 뒤에 추가 크레딧 창이 마지막으로 붙는다.
        let json = #"""
        {"limits": [{"kind": "session", "group": "session", "percent": 40}],
         "extra_usage": {"is_enabled": true, "monthly_limit": 4000, "used_credits": 0}}
        """#
        let resp = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
        let windows = ClaudeUsageMapper.windows(from: resp)
        #expect(windows.count == 2)
        #expect(windows.first?.label == "Current session")
        #expect(windows.last?.label == "Extra usage")
    }
}
