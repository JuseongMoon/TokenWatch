//
//  GrokUsageTests.swift
//  TokenWatchTests
//
//  Grok 주간 사용량 매핑 검증. 픽스처는 TokenBar `agent_grok.rs`의 실측 응답·회귀 사례를 옮겼다.
//  (네트워크 없이 응답 바이트 → 창 매핑만 본다.)
//

import Testing
import Foundation
@testable import TokenWatch

@MainActor
struct GrokUsageTests {

    private func usage(_ json: String) throws -> (windows: [UsageWindow], plan: String?) {
        try GrokBillingMapper.usage(from: Data(json.utf8))
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter.tokenwatchNoFraction.date(from: text)!
    }

    private let weeklyPeriod = #""currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-15T00:00:00+00:00","end":"2026-07-22T00:00:00+00:00"}"#

    /// 실측 응답: 주간 풀 4% 사용 → 창 하나(리셋·7일 창 길이·플랜).
    @Test func 실측_주간_응답을_창_하나로_매핑한다() throws {
        let json = """
        {"config":{\(weeklyPeriod),
          "creditUsagePercent":4.0,"productUsage":[{"product":"GrokBuild","usagePercent":4.0}],"isUnifiedBillingUser":true,
          "billingPeriodStart":"2026-07-15T00:00:00+00:00","billingPeriodEnd":"2026-07-22T00:00:00+00:00"},
         "subscriptionTiers":"X Premium+"}
        """
        let result = try usage(json)
        #expect(result.windows.count == 1)
        let window = result.windows.first
        #expect(window?.label == "Current week")
        #expect(window?.usedPercent == 4)
        #expect(window?.kind == .weekly)
        #expect(window?.style == .gauge)
        #expect(window?.windowSeconds == 604_800)
        #expect(window?.resetsAt == date("2026-07-22T00:00:00Z"))
        #expect(result.plan == "X Premium+")
    }

    /// 리셋 직후 실측 응답: 퍼센트 필드가 생략되고 주간 period만 온다 → 0% 사용.
    @Test func 리셋_직후_퍼센트가_없으면_0퍼센트다() throws {
        let json = """
        {"config":{\(weeklyPeriod),
          "onDemandCap":{"val":0},"isUnifiedBillingUser":true,
          "billingPeriodStart":"2026-07-15T00:00:00+00:00","billingPeriodEnd":"2026-07-22T00:00:00+00:00"}}
        """
        let window = try usage(json).windows.first
        #expect(window?.usedPercent == 0)
        #expect(window?.resetsAt == date("2026-07-22T00:00:00Z"))
    }

    /// TokenBar #240: 풀은 소진(100%)인데 CLI 제품 몫은 96% — 제품 행이 아니라 풀을 읽어야 한다.
    @Test func 소진된_풀은_제품_행과_무관하게_100퍼센트다() throws {
        let json = """
        {"config":{\(weeklyPeriod),"creditUsagePercent":100.0,
          "productUsage":[{"product":"GrokChat","usagePercent":4.0},{"product":"GrokBuild","usagePercent":96.0}]}}
        """
        let result = try usage(json)
        #expect(result.windows.count == 1)
        #expect(result.windows.first?.usedPercent == 100)
        #expect(result.windows.first?.remainingPercent == 0)
    }

    /// 자정이 아닌 시각에 마이크로초까지 붙은 period(실측)도 읽는다.
    @Test func 마이크로초가_붙은_period를_읽는다() throws {
        let json = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-07T15:40:06.727001+00:00","end":"2026-07-14T15:40:06.727001+00:00"},
          "creditUsagePercent":4.0,"billingPeriodEnd":"2026-07-14T15:40:06.727001+00:00"},
         "subscriptionTiers":"X Premium+"}
        """
        let window = try usage(json).windows.first
        let expectedReset = date("2026-07-14T15:40:06Z").addingTimeInterval(0.727001)
        #expect(window?.resetsAt != nil)
        #expect(abs(window?.resetsAt?.timeIntervalSince(expectedReset) ?? 99) < 0.001)
        #expect(abs((window?.windowSeconds ?? 0) - 604_800) < 0.001)
    }

    @Test func 시각_파서는_소수_자릿수와_무관하다() {
        let base = date("2026-07-14T15:40:06Z")
        #expect(GrokBillingMapper.parseDate("2026-07-14T15:40:06Z") == base)
        #expect(abs((GrokBillingMapper.parseDate("2026-07-14T15:40:06.5+00:00")?.timeIntervalSince(base) ?? 99) - 0.5) < 0.001)
        #expect(abs((GrokBillingMapper.parseDate("2026-07-14T15:40:06.727001+00:00")?.timeIntervalSince(base) ?? 99) - 0.727001) < 0.001)
        #expect(GrokBillingMapper.parseDate("not-a-date") == nil)
    }

    /// 사용률을 확정할 근거가 없으면 0%로 만들지 않고 창을 내지 않는다(→ noWindows 오류로 표시).
    @Test func 근거_없는_응답은_창이_없다() throws {
        #expect(try usage(#"{"config":{}}"#).windows.isEmpty)
        #expect(try usage("{}").windows.isEmpty)
    }

    @Test func 범위를_벗어나거나_숫자가_아닌_퍼센트는_오류다() {
        for bad in ["150", "-1", #""4.0""#, "true"] {
            let json = #"{"config":{"creditUsagePercent":"# + bad + "}}"
            #expect(throws: UsageError.self, "\(bad)") { try usage(json) }
        }
    }

    /// 퍼센트가 없는데 제품 행이 사용량을 보고하면 빈 주가 아니다 → 0%로 만들지 않는다.
    @Test func 퍼센트_없이_제품_사용량이_있으면_오류다() throws {
        let used = #"{"config":{"# + weeklyPeriod + #","productUsage":[{"product":"GrokBuild","usagePercent":12.5}]}}"#
        #expect(throws: UsageError.self) { try usage(used) }

        let zero = #"{"config":{"# + weeklyPeriod + #","productUsage":[{"product":"GrokBuild","usagePercent":0}]}}"#
        #expect(try usage(zero).windows.first?.usedPercent == 0)
    }

    /// 0% 추정은 "스스로 완결된 주간 period"에서만 — 비주간·부분 period, 평면 billingPeriod* 빌려오기는 불가.
    @Test func 비주간이나_불완전한_period는_0퍼센트로_읽지_않는다() throws {
        let cases = [
            #"{"config":{"currentPeriod":{}}}"#,
            #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY"}}}"#,
            #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY","start":"2026-07-01T00:00:00+00:00","end":"2026-08-01T00:00:00+00:00"}}}"#,
            #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY"},"billingPeriodStart":"2026-07-15T00:00:00+00:00","billingPeriodEnd":"2026-07-22T00:00:00+00:00"}}"#,
            #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_BIWEEKLY","start":"2026-07-15T00:00:00+00:00","end":"2026-07-22T00:00:00+00:00"}}}"#,
            #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_NOT_WEEKLY","start":"2026-07-15T00:00:00+00:00","end":"2026-07-22T00:00:00+00:00"}}}"#,
        ]
        for json in cases {
            #expect(try usage(json).windows.isEmpty, "\(json)")
        }
    }

    /// currentPeriod가 없으면 리셋·창 길이는 평면 billingPeriod*로 폴백한다.
    @Test func 리셋은_billingPeriodEnd로_폴백한다() throws {
        let json = #"{"config":{"creditUsagePercent":30,"billingPeriodStart":"2026-07-15T00:00:00+00:00","billingPeriodEnd":"2026-07-22T00:00:00+00:00"}}"#
        let window = try usage(json).windows.first
        #expect(window?.usedPercent == 30)
        #expect(window?.resetsAt == date("2026-07-22T00:00:00Z"))
        #expect(window?.windowSeconds == 604_800)
    }

    /// null 퍼센트는 "생략"과 같다 — 주간 period가 있으면 0%.
    @Test func null_퍼센트는_생략으로_본다() throws {
        let json = #"{"config":{"# + weeklyPeriod + #","creditUsagePercent":null}}"#
        #expect(try usage(json).windows.first?.usedPercent == 0)
    }

    /// 플랜 라벨은 선택 필드 — 형식이 달라도 사용량 파싱을 깨지 않는다.
    @Test func 플랜_라벨은_선택_필드다() throws {
        let config = #""config":{"creditUsagePercent":10,"billingPeriodEnd":"2026-07-22T00:00:00+00:00"}"#
        #expect(try usage("{" + config + #","subscriptionTiers":"  SuperGrok  "}"#).plan == "SuperGrok")
        #expect(try usage("{" + config + #","subscriptionTiers":"   "}"#).plan == nil)
        #expect(try usage("{" + config + "}").plan == nil)
        #expect(try usage("{" + config + #","subscriptionTiers":42}"#).plan == nil)
        #expect(try usage("{" + config + #","subscriptionTiers":["SuperGrok","X Premium+"]}"#).plan == "SuperGrok, X Premium+")
        #expect(try usage("{" + config + #","subscriptionTiers":42}"#).windows.count == 1)
    }
}
