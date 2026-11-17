//
//  FirstRunEntryTests.swift
//  TokenWatchTests
//
//  첫 실행 이탈 개선 회귀: 계정 추가 화면 `screen_view`에 들어온 경로(`source`)를 열거값으로 싣고,
//  빈 첫 화면·데모 중 연결 안내 문구가 두 언어로 있다(Android와 같은 문자열).
//

import Testing
import Foundation
@testable import TokenWatch

@MainActor
struct FirstRunEntryTests {
    typealias Source = AnalyticsEvent.AddAgentSource

    @Test func 추가_화면_screen_view는_들어온_경로를_싣는다() {
        let cases: [(Source, String)] = [(.emptyState, "empty_state"), (.demo, "demo"), (.list, "list")]
        for (source, tag) in cases {
            let params = AnalyticsEvent.screenView(.addAgent, source: source).parameters
            #expect(params["screen_name"] as? String == "add_agent")
            #expect(params["source"] as? String == tag)
            #expect(params["provider"] == nil)
        }
        // 다른 화면에는 source를 싣지 않는다(기존 파라미터 그대로).
        let main = AnalyticsEvent.screenView(.main).parameters
        #expect(Set(main.keys) == ["screen_name", "screen_class"])
        let detail = AnalyticsEvent.screenView(.agentDetail, provider: .codex).parameters
        #expect(Set(detail.keys) == ["screen_name", "screen_class", "provider"])
    }

    @Test func screen_view는_데모_게이트의_provider_이벤트가_아니다() {
        // 데모를 끝낸 뒤 여는 추가 화면은 기록돼야 한다(provider 차원 이벤트만 데모에서 막힌다).
        #expect(!AnalyticsEvent.screenView(.addAgent, source: .demo).isProviderScoped)
    }

    @Test func 추가_시트의_기본_경로는_list다() {
        #expect(AddAgentSheet().source == .list)
        #expect(AddAgentSheet(source: .emptyState).source == .emptyState)
        #expect(AddAgentSheet(source: .demo).source == .demo)
    }

    @Test func 빈_첫_화면과_데모_연결_안내_문구() {
        let ko = L10n(lang: .ko), en = L10n(lang: .en)
        #expect(ko.emptyStateMessage == "아직 연결한 계정이 없습니다. 쓰고 있는 AI 서비스를 연결하면 남은 사용량이 여기에 표시됩니다.")
        #expect(en.emptyStateMessage == "No accounts connected yet. Connect the AI services you use to see your remaining usage here.")
        #expect(ko.demoConnectMessage == "데모 화면입니다. 내 계정을 연결하면 실제 사용량이 표시됩니다.")
        #expect(en.demoConnectMessage == "This is a demo. Connect your own account to see your real usage.")
        // 몬스터 출현 주기·확률을 암시하지 않는다.
        for text in [ko.emptyStateMessage, en.emptyStateMessage, ko.demoConnectMessage, en.demoConnectMessage] {
            #expect(!text.contains("몬스터") && !text.lowercased().contains("monster"))
        }
    }
}
