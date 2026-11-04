//
//  CopilotUsageMappingTests.swift
//  TokenWatchTests
//
//  Copilot `copilot_internal/user` 응답 매핑(Android와 같은 레인별 규칙): 유료(`quota_snapshots`),
//  Free(`limited_user_quotas`/`monthly_quotas`, chat·completions 레인만), 둘이 섞인 응답, 쿼터 정보가 없는 200.
//  응답 예시는 공개 구현(OpenUsage·CodexBar 테스트)의 형태를 본뜬 합성 값이다.
//

import Testing
import Foundation
@testable import TokenWatch

@MainActor
struct CopilotUsageMappingTests {
    private func map(_ json: String) throws -> [UsageWindow] {
        try CopilotUsageClient.windows(from: Data(json.utf8))
    }

    // MARK: 유료(quota_snapshots)

    @Test func 유료_응답은_기존처럼_premium_chat_completions_순서로_매핑한다() throws {
        let windows = try map("""
        {"copilot_plan":"individual","quota_reset_date":"2026-12-01",
         "quota_snapshots":{
           "completions":{"entitlement":0,"remaining":0,"percent_remaining":100,"unlimited":true},
           "chat":{"entitlement":-1,"remaining":-1,"unlimited":false},
           "premium_interactions":{"entitlement":300,"remaining":225,"percent_remaining":75,"unlimited":false}
         }}
        """)
        // 무제한(unlimited 플래그·-1)은 숨기고 premium만 남는다.
        #expect(windows.map(\.label) == ["Premium requests"])
        #expect(windows.first?.usedPercent == 25)
        #expect(windows.first?.resetsAt != nil)
    }

    @Test func percent가_없으면_한도와_남은_양으로_계산하고_수치가_없으면_표시하지_않는다() throws {
        let windows = try map("""
        {"quota_snapshots":{
           "premium_interactions":{"entitlement":50,"remaining":40},
           "chat":{"unlimited":false},
           "zeta_quota":{"entitlement":10,"remaining":5},
           "alpha_quota":{"percent_remaining":90}
         }}
        """)
        // chat은 수치가 없어 가짜 0% 게이지를 만들지 않는다. 그 밖의 키는 이름순, 라벨은 단어 대문자화.
        #expect(windows.map(\.label) == ["Premium requests", "Alpha Quota", "Zeta Quota"])
        #expect(windows.map(\.usedPercent) == [20, 10, 50])
    }

    // MARK: Free(limited_user_quotas / monthly_quotas)

    @Test func Free_응답은_남은_양과_월_한도로_사용률을_낸다() throws {
        let windows = try map("""
        {"copilot_plan":"free","limited_user_reset_date":"2026-12-04",
         "monthly_quotas":{"chat":"500","completions":300},
         "limited_user_quotas":{"chat":125,"completions":"75"}}
        """)
        #expect(windows.map(\.label) == ["Chat", "Completions"])
        #expect(windows.map(\.usedPercent) == [75, 75])
        // quota_reset_date가 없으면 limited_user_reset_date를 리셋 시각으로 쓴다.
        #expect(windows.allSatisfy { $0.resetsAt != nil })
    }

    @Test func Free_남은_양이_없는_쿼터는_가득_남음으로_가정하지_않는다() throws {
        #expect(try map("""
        {"copilot_plan":"free","monthly_quotas":{"chat":500,"completions":300}}
        """).isEmpty)

        let partial = try map("""
        {"copilot_plan":"free","monthly_quotas":{"chat":500,"completions":300},
         "limited_user_quotas":{"completions":60}}
        """)
        #expect(partial.map(\.label) == ["Completions"])
        #expect(partial.first?.usedPercent == 80)
    }

    @Test func Free_사용량이_한도를_넘거나_음수여도_0에서_100으로_자른다() throws {
        let windows = try map("""
        {"monthly_quotas":{"chat":100,"completions":100},
         "limited_user_quotas":{"chat":-5,"completions":150}}
        """)
        #expect(windows.map(\.usedPercent) == [100, 0])
    }

    // MARK: 레인별 혼합(Android와 같은 규칙)

    @Test func 혼합_응답은_premium은_스냅샷으로_chat_completions는_Free로_채운다() throws {
        let windows = try map("""
        {"quota_reset_date":"2026-12-01",
         "quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":60}},
         "monthly_quotas":{"chat":"500","completions":200},
         "limited_user_quotas":{"chat":400,"completions":"50"}}
        """)
        #expect(windows.map(\.label) == ["Premium requests", "Chat", "Completions"])
        #expect(windows.map(\.usedPercent) == [80, 20, 75])
    }

    @Test func 스냅샷이_측정된_레인은_Free_값보다_우선한다() throws {
        let windows = try map("""
        {"quota_snapshots":{"chat":{"percent_remaining":10}},
         "monthly_quotas":{"chat":500},"limited_user_quotas":{"chat":500}}
        """)
        #expect(windows.map(\.label) == ["Chat"])
        #expect(windows.first?.usedPercent == 90)
    }

    @Test func 무제한_레인은_숨기고_Free_값으로도_채우지_않는다() throws {
        let windows = try map("""
        {"quota_snapshots":{"chat":{"unlimited":true},"completions":{"entitlement":-1,"remaining":-1}},
         "monthly_quotas":{"chat":500,"completions":300},
         "limited_user_quotas":{"chat":100,"completions":150}}
        """)
        #expect(windows.isEmpty)
    }

    @Test func 측정_불가_스냅샷은_숨기되_chat_completions는_Free_값으로_채운다() throws {
        let windows = try map("""
        {"quota_snapshots":{
           "premium_interactions":{},
           "chat":{"entitlement":0,"remaining":0},
           "completions":{}
         },
         "monthly_quotas":{"chat":100,"completions":300,"premium_interactions":100},
         "limited_user_quotas":{"chat":25,"completions":150,"premium_interactions":10}}
        """)
        // premium은 Free 레인이 아니라 Free 값이 있어도 채우지 않는다.
        #expect(windows.map(\.label) == ["Chat", "Completions"])
        #expect(windows.map(\.usedPercent) == [75, 50])
    }

    @Test func Free_값은_chat_completions_외의_키에_쓰지_않는다() throws {
        let windows = try map("""
        {"monthly_quotas":{"chat":100,"code_review":50},
         "limited_user_quotas":{"chat":50,"code_review":10}}
        """)
        #expect(windows.map(\.label) == ["Chat"])
    }

    @Test func Free_한도가_0_이하면_그_레인을_표시하지_않는다() throws {
        #expect(try map("""
        {"monthly_quotas":{"chat":0,"completions":-3},
         "limited_user_quotas":{"chat":0,"completions":1}}
        """).isEmpty)
    }

    // MARK: 쿼터 정보 없음

    @Test func 쿼터_키가_없는_200은_빈_창으로_돌려_데이터_없음으로_처리되게_한다() throws {
        // 구독이 끝난 계정 등. 빈 배열은 ProviderUsage가 noWindows("표시할 사용량 창이 없습니다")로 바꾼다.
        #expect(try map(#"{"copilot_plan":"individual","access_type_sku":"free_limited_copilot"}"#).isEmpty)
        #expect(try map(#"{"quota_snapshots":{}}"#).isEmpty)
    }

    @Test func JSON_객체가_아니면_해석_실패다() {
        #expect(throws: UsageError.self) { try map("[]") }
        #expect(throws: UsageError.self) { try map("not json") }
    }

    @Test func 라벨_문자열이_Android와_맞춘_값이다() {
        #expect(CopilotUsageClient.label(for: "premium_interactions") == "Premium requests")
        #expect(CopilotUsageClient.label(for: "chat") == "Chat")
        #expect(CopilotUsageClient.label(for: "completions") == "Completions")
        #expect(CopilotUsageClient.label(for: "some_new_quota") == "Some New Quota")
    }
}
