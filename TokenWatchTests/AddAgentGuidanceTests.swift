//
//  AddAgentGuidanceTests.swift
//  TokenWatchTests
//
//  추가 화면 안내 회귀: Claude 로그인 전 안내(Android와 바이트 단위로 같은 문구),
//  API 키 입력 화면 첫머리의 서비스별 안내(OpenRouter는 관리 키 필요를 입력 전에 알린다).
//

import Testing
import Foundation
@testable import TokenWatch

@MainActor
struct AddAgentGuidanceTests {
    // MARK: Claude 로그인 전 안내

    @Test func Claude_로그인_전_안내는_Android와_같은_문구다() {
        #expect(L10n(lang: .ko).claudeLoginNotice
                == "다음 화면에서 Anthropic 로그인과 권한 동의를 진행합니다. TokenWatch는 이 연결을 계정 이메일·조직 이름 표시와 남은 사용량·리셋 시간 조회에만 쓰며, 메시지를 보내지 않습니다. 로그인 토큰은 이 기기의 보안 저장소에만 저장되고 개발자 서버로 보내지 않습니다.")
        #expect(L10n(lang: .en).claudeLoginNotice
                == "Next, you'll sign in to Anthropic and review the permission request. TokenWatch uses this connection only to show your account email and organization name and to read your remaining usage and reset times. It never sends messages. Your sign-in token is stored only in this device's secure storage and is never sent to our servers.")
    }

    @Test func Claude_안내에는_근거_없는_단정이나_클라이언트_이름이_없다() {
        for text in [L10n(lang: .ko).claudeLoginNotice, L10n(lang: .en).claudeLoginNotice] {
            for banned in ["공식", "표준", "official", "standard", "Claude Code"] {
                #expect(!text.contains(banned), "\(banned)")
            }
        }
    }

    // MARK: API 키 안내

    @Test func API_키_provider마다_두_언어_안내가_있고_그_외에는_없다() {
        for provider in AgentProvider.allCases {
            let ko = L10n(lang: .ko).apiKeyGuide(provider: provider)
            let en = L10n(lang: .en).apiKeyGuide(provider: provider)
            if provider.authKind == .apiKey {
                #expect(ko?.isEmpty == false, "\(provider)")
                #expect(en?.isEmpty == false, "\(provider)")
                #expect(ko != en, "\(provider)")
            } else {
                #expect(ko == nil && en == nil, "\(provider)")
            }
        }
    }

    @Test func OpenRouter_안내는_입력_전에_관리_키가_필요하다고_알린다() {
        let ko = L10n(lang: .ko).apiKeyGuide(provider: .openrouter) ?? ""
        let en = L10n(lang: .en).apiKeyGuide(provider: .openrouter) ?? ""
        #expect(ko.hasPrefix("일반 API 키가 아니라 관리 키(Management Key)"))
        #expect(en.hasPrefix("This needs a Management Key, not a regular API key."))
        #expect(AgentProvider.openrouter.apiKeyURL?.path == "/settings/management-keys")
    }
}
