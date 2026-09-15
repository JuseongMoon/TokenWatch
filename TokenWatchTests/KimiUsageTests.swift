//
//  KimiUsageTests.swift
//  TokenWatchTests
//
//  Kimi Code `/coding/v1/usages` → 창 매핑 검증. 구형 픽스처는 실측 응답(pi-web #848, 2026-09-14)과
//  CodexBar 문서 샘플, 신형은 공식 kimi-code CLI 파서·테스트 형식을 따른다. (네트워크 없이 매핑만 본다.)
//

import Testing
import Foundation
@testable import TokenWatch

@MainActor
struct KimiUsageTests {

    private func windows(_ json: String) throws -> [UsageWindow] {
        try KimiUsageMapper.windows(from: Data(json.utf8))
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter.tokenwatchDate(from: text)!
    }

    /// 실측 구형(퍼센트형): 5시간 1% 사용, 주간은 `used` 없이 remaining만 와서 0%.
    @Test func 실측_구형_응답을_5시간과_주간으로_매핑한다() throws {
        let json = """
        {"user":{"membership":{"level":"LEVEL_ADVANCED"}},
         "usage":{"limit":"100","remaining":"100","resetTime":"2026-09-21T03:17:42Z"},
         "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                    "detail":{"limit":"100","used":"1","remaining":"99","resetTime":"2026-09-14T10:17:42Z"}}],
         "parallel":{"limit":"30"},
         "authentication":{"method":"METHOD_API_KEY","scope":"FEATURE_CODING"}}
        """
        let result = try windows(json)
        #expect(result.map(\.label) == ["Current session", "Current week"])
        #expect(result.map(\.usedPercent) == [1, 0])
        #expect(result.map(\.kind) == [.session, .weekly])
        #expect(result.first?.windowSeconds == 5 * 3600)
        #expect(result.last?.windowSeconds == 7 * 24 * 3600)
        #expect(result.first?.resetsAt == date("2026-09-14T10:17:42Z"))
        #expect(result.last?.resetsAt == date("2026-09-21T03:17:42Z"))
    }

    /// 요청 수형 구형(2026-01): 수는 문자열, 시각에 나노초 자리까지 붙는다.
    @Test func 요청_수형_구형과_긴_소수_시각을_읽는다() throws {
        let json = """
        {"usage":{"limit":"2048","used":"214","remaining":"1834","resetTime":"2026-01-09T15:23:13.716839300Z"},
         "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                    "detail":{"limit":"200","used":"139","remaining":"61","resetTime":"2026-01-06T12:00:00Z"}}]}
        """
        let result = try windows(json)
        #expect(abs((result.first?.usedPercent ?? 0) - 69.5) < 0.001)
        #expect(abs((result.last?.usedPercent ?? 0) - 214.0 / 2048 * 100) < 0.001)
        let expected = date("2026-01-09T15:23:13Z").addingTimeInterval(0.7168393)
        #expect(abs((result.last?.resetsAt?.timeIntervalSince(expected)) ?? 99) < 0.001)
    }

    /// 신형(공식 CLI 2026-09-15): used_ratio 0~1, 문자열 비율도 받는다.
    @Test func 신형_응답을_비율로_매핑한다() throws {
        let json = """
        {"usages":{"limit_5h":{"used_ratio":0.25,"reset_time":"2026-09-15T12:00:00Z"},
                   "limit_7d":{"used_ratio":"0.5","reset_time":"2026-09-20T00:00:00Z"}}}
        """
        let result = try windows(json)
        #expect(result.map(\.label) == ["Current session", "Current week"])
        #expect(result.map(\.usedPercent) == [25, 50])
        #expect(result.last?.resetsAt == date("2026-09-20T00:00:00Z"))
    }

    /// 신 플랜: 5시간 + 월간(전체·Code). 월간은 창 길이를 모른다.
    @Test func 신_플랜_월간_두_항목을_만든다() throws {
        let json = """
        {"usages":{"limit_5h":{"used_ratio":0.1,"reset_time":"2026-09-15T12:00:00Z"},
                   "limit_month_total":{"used_ratio":0.4,"reset_time":"2026-10-01T00:00:00Z"},
                   "limit_month_code":{"used_ratio":0.3,"reset_time":"2026-10-01T00:00:00Z"}}}
        """
        let result = try windows(json)
        #expect(result.map(\.label) == ["Current session", "Current month", "Current month (Code)"])
        #expect(result.map { ($0.usedPercent * 10).rounded() / 10 } == [10, 40, 30])
        #expect(result.last?.windowSeconds == nil)
    }

    /// 형식 전환 중 신형이 비어 있으면 구형을 읽는다(데이터를 잃지 않게).
    @Test func 신형이_비면_구형으로_읽는다() throws {
        let json = #"{"usages":{},"usage":{"limit":"100","used":"12","remaining":"88","resetTime":"2026-09-21T03:17:42Z"}}"#
        #expect(try windows(json).map(\.usedPercent) == [12])
    }

    /// 쓸 수 있는 값이 없으면 창을 만들지 않는다 → 카드에 noWindows 오류로 보인다.
    @Test func 쓸_값이_없으면_창이_없다() throws {
        #expect(try windows("{}").isEmpty)
        #expect(try windows(#"{"usages":{"limit_5h":{"used_ratio":"abc"}}}"#).isEmpty)
        #expect(try windows(#"{"usage":{"limit":"0","remaining":"0"}}"#).isEmpty)
        // 5시간이 아닌 창만 있으면 5시간 창으로 착각하지 않는다.
        #expect(try windows(#"{"limits":[{"window":{"duration":1,"timeUnit":"TIME_UNIT_DAY"},"detail":{"limit":"10","used":"1"}}]}"#).isEmpty)
    }

    @Test func JSON_객체가_아니면_오류다() {
        #expect(throws: UsageError.self) { try windows("[]") }
        #expect(throws: UsageError.self) { try windows("not json") }
    }

    @Test func 범위를_벗어난_값은_0에서_100으로_자른다() throws {
        let json = #"{"usages":{"limit_5h":{"used_ratio":1.3},"limit_7d":{"used_ratio":-0.2}}}"#
        #expect(try windows(json).map(\.usedPercent) == [100, 0])
    }

    /// `/me`는 이메일·전화번호도 주지만 플랜 이름만 꺼낸다.
    @Test func 플랜_이름은_user_level_name만_읽는다() {
        let me = #"{"user_id":"u_1","user_level":30,"user_level_name":"Vivace","email":"user@example.com","phone":{"country_code":"86","number":"176****0000"}}"#
        #expect(KimiUsageMapper.planName(from: Data(me.utf8)) == "Vivace")
        #expect(KimiUsageMapper.planName(from: Data(#"{"user_level_name":""}"#.utf8)) == nil)
        #expect(KimiUsageMapper.planName(from: Data("[]".utf8)) == nil)
    }

    @Test func 숫자와_숫자_문자열만_수로_읽는다() {
        #expect(KimiUsageMapper.number("100") == 100)
        #expect(KimiUsageMapper.number(NSNumber(value: 1)) == 1)
        #expect(KimiUsageMapper.number(NSNumber(value: true)) == nil)
        #expect(KimiUsageMapper.number("abc") == nil)
        #expect(KimiUsageMapper.number(nil) == nil)
    }

    @Test func Kimi는_API_키_방식이고_두_지역_호스트를_순서대로_본다() {
        #expect(AgentProvider.kimi.authKind == .apiKey)
        #expect(AgentProvider.kimi.apiKeyURL?.host() == "www.kimi.com")
        #expect(KimiUsageClient.hosts == ["api.kimi.com", "api.kimi.ai"])
        #expect(KimiUsageClient.usagesURL(host: "api.kimi.ai").absoluteString
                == "https://api.kimi.ai/coding/v1/usages")
        #expect(L10n(lang: .ko).apiKeyHint(provider: .kimi) != nil)
        #expect(L10n(lang: .en).apiKeyHint(provider: .openrouter) == nil)
    }
}
