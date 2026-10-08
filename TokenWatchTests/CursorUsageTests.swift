//
//  CursorUsageTests.swift
//  TokenWatchTests
//
//  Cursor usage-summary → 창 매핑 검증. 픽스처는 실측 샘플(KyleBing/m5stack-cardputer-sparks `api/cursor`)과
//  CodexBar 테스트 응답을 옮겼다. (네트워크 없이 응답 바이트 → 창 매핑만 본다.)
//

import Testing
import Foundation
@testable import TokenWatch

@MainActor
struct CursorUsageTests {

    private func usage(_ json: String) throws -> (windows: [UsageWindow], plan: String?) {
        try CursorUsageMapper.usage(from: Data(json.utf8))
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter.tokenwatchDate(from: text)!
    }

    /// 실측 샘플(Pro): 포함 사용량 소진 — Other models 100%, Cursor models 0%, 결제 주기 끝에 리셋.
    @Test func 실측_Pro_응답을_풀_두_개로_매핑한다() throws {
        let json = """
        {"billingCycleStart":"2026-04-02T14:11:55.000Z","billingCycleEnd":"2026-05-02T14:11:55.000Z",
         "membershipType":"pro","limitType":"user","isUnlimited":false,
         "individualUsage":{"plan":{"enabled":true,"used":2000,"limit":2000,"remaining":0,
           "autoPercentUsed":0,"apiPercentUsed":100,"totalPercentUsed":100,
           "breakdown":{"included":2000,"bonus":0,"total":2000}},
          "onDemand":{"enabled":true,"used":2309,"limit":10000,"remaining":7691}},
         "teamUsage":{"onDemand":{"enabled":true,"used":5000,"limit":50000,"remaining":45000}}}
        """
        let result = try usage(json)
        #expect(result.windows.map(\.label) == ["Cursor models", "Other models"])
        #expect(result.windows.map(\.usedPercent) == [0, 100])
        #expect(result.windows.allSatisfy { $0.kind == .weekly && $0.style == .gauge })
        #expect(result.windows.first?.resetsAt == date("2026-05-02T14:11:55.000Z"))
        #expect(result.windows.first?.windowSeconds == 30 * 24 * 3600)
        #expect(result.plan == "Pro")
    }

    /// 두 풀 퍼센트는 이미 %다(10 = 10%). 대시보드와 어긋난 사례가 있는 totalPercentUsed(30)는 쓰지 않는다.
    @Test func 퍼센트는_그대로_쓰고_total은_쓰지_않는다() throws {
        let json = """
        {"billingCycleStart":"2026-09-01T00:00:00Z","billingCycleEnd":"2026-10-01T00:00:00Z",
         "membershipType":"pro","individualUsage":{"plan":{"enabled":true,"used":1500,
         "limit":5000,"remaining":3500,"totalPercentUsed":30,"autoPercentUsed":10,"apiPercentUsed":20}}}
        """
        let result = try usage(json)
        #expect(result.windows.map(\.usedPercent) == [10, 20])
        #expect(result.windows.first?.resetsAt == date("2026-10-01T00:00:00Z"))
        #expect(!result.windows.contains { $0.usedPercent == 30 })
    }

    /// Start 플랜처럼 한 풀만 있으면 그 창만 만든다.
    @Test func 퍼센트가_있는_풀만_창으로_만든다() throws {
        let json = #"{"billingCycleEnd":"2026-10-01T00:00:00Z","membershipType":"express","individualUsage":{"plan":{"autoPercentUsed":42.5}}}"#
        let result = try usage(json)
        #expect(result.windows.map(\.label) == ["Cursor models"])
        #expect(result.windows.first?.usedPercent == 42.5)
        // 시작 시각이 없으면 창 길이를 모른다.
        #expect(result.windows.first?.windowSeconds == nil)
        #expect(result.plan == "Start")
    }

    /// 풀 퍼센트가 없는 구형 응답은 포함 사용량 금액(센트)으로 한 창을 만든다.
    @Test func 풀_퍼센트가_없으면_포함_사용량_금액으로_폴백한다() throws {
        let json = #"{"billingCycleEnd":"2026-10-01T00:00:00Z","individualUsage":{"plan":{"used":500,"limit":2000}}}"#
        let result = try usage(json)
        #expect(result.windows.map(\.label) == ["Included usage"])
        #expect(result.windows.first?.usedPercent == 25)
    }

    /// 형식이 바뀐 200은 0%로 보이지 않고 오류다.
    @Test func 결제_주기나_플랜_사용량이_없으면_오류다() {
        let cases = [
            #"{}"#,
            #"{"individualUsage":{"plan":{"autoPercentUsed":10}}}"#,
            #"{"billingCycleEnd":"2026-10-01T00:00:00Z","individualUsage":{}}"#,
            #"{"billingCycleEnd":"not-a-date","individualUsage":{"plan":{"autoPercentUsed":10}}}"#,
        ]
        for json in cases {
            #expect(throws: UsageError.self, "\(json)") { try usage(json) }
        }
    }

    @Test func 범위를_벗어난_퍼센트는_0에서_100으로_자른다() throws {
        let json = #"{"billingCycleEnd":"2026-10-01T00:00:00Z","individualUsage":{"plan":{"autoPercentUsed":130,"apiPercentUsed":-5}}}"#
        #expect(try usage(json).windows.map(\.usedPercent) == [100, 0])
    }

    @Test func 플랜_이름을_표시용으로_바꾼다() {
        #expect(CursorUsageMapper.planLabel("pro_plus") == "Pro Plus")
        #expect(CursorUsageMapper.planLabel("ultra") == "Ultra")
        #expect(CursorUsageMapper.planLabel("free") == "Hobby")
        #expect(CursorUsageMapper.planLabel("express") == "Start")
        #expect(CursorUsageMapper.planLabel("new_tier_x") == "New Tier X")
        #expect(CursorUsageMapper.planLabel(nil) == nil)
        #expect(CursorUsageMapper.planLabel("  ") == nil)
    }
}
