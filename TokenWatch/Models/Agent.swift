//
//  Agent.swift
//  TokenWatch
//
//  로그인된 AI 에이전트 1개를 나타내는 모델.
//

import Foundation
import SwiftUI

/// provider가 사용자 자격증명을 얻는 방식. `AddAgentSheet`가 이 값으로 로그인 UI를 분기한다.
/// (새 provider를 추가할 때 이 중 하나를 고른다.)
enum AuthKind: Sendable {
    /// WKWebView로 로그인 → OAuth 콜백 리다이렉트에서 code를 가로챈다. (Codex)
    /// 주의: 이 방식은 `window.open` 팝업으로 동작하는 소셜 로그인(구글 등)을 지원하지 못한다.
    case oauthCode
    /// 앱 안의 시스템 인증 시트(ASWebAuthenticationSession)로 로그인 → 루프백 콜백으로 code를
    /// 자동 수신한다. Claude는 폴백으로 콘솔 페이지의 코드를 복사해 붙여넣을 수도 있다. (Claude, Grok)
    /// Safari 엔진이라 팝업 기반 소셜 로그인(구글)도 동작한다. 케이스 이름은 분석 값과 묶여 있어 유지한다.
    case oauthBrowser
    /// 승인 페이지를 앱 안 Safari View로 열고 토큰을 폴링한다. Copilot은 user code를 입력하고, Cursor는 페이지 승인만 한다.
    case oauthDeviceFlow
    /// 사용자가 발급한 API 키를 직접 붙여넣는다. (예: ElevenLabs/OpenRouter)
    case apiKey
}

/// 이 provider가 보여주는 "사용량"의 성격. 카드/상세에서 구독 잔여와 개발자 크레딧을 구분 표기한다.
/// (구독 사용량 ≠ 개발자 API 선불 크레딧 — 사용자 혼동을 막기 위한 라벨용.)
enum UsageCategory: Sendable {
    /// 로그인한 구독자의 남은 할당량. (Claude/Codex 등)
    case subscription
    /// 개발자가 API 키로 충전한 선불 잔액/크레딧.
    case apiCredit
}

/// 지원하는 AI 에이전트 제공자.
///
/// 여기 남은 provider는 전부 "공식 문서화된 조회 경로 또는 실증된 엔드포인트"만이다.
/// 리버스 엔지니어링 의존이 컸던 세션 캡처형(Cursor/Grok/Windsurf)과 개발자 API
/// 선불 크레딧만 보여주던 창작 계열(fal/Stability/Recraft/Luma/Runway/D-ID/HeyGen/
/// Leonardo)은 2026-08 정리에서 제거했다 — 동작이 애매한 provider를 노출하지 않기 위함.
/// (제거된 rawValue를 가진 저장 데이터는 `AgentStore.load()`가 걸러낸다.)
/// Grok은 2026-09에 방식을 바꿔 다시 넣었다: grok.com 쿠키 대신 공식 Grok CLI의 OAuth와,
/// 잘못된 토큰에 401을 돌려주는 JSON 사용량 엔드포인트를 쓴다(로그인 만료를 감지할 수 있다).
/// Cursor도 2026-09에 다시 넣었다: 쿠키 캡처 대신 Cursor CLI와 같은 로그인(페이지 승인 + 폴링)과, 세션이
/// 없으면 401을 주는 대시보드 사용량 요약(usage-summary)을 쓴다. 공식 API는 아니다.
enum AgentProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case copilot
    case grok
    case cursor
    case openrouter
    case deepseek
    case poe
    case elevenlabs

    var id: String { rawValue }

    /// 리스트/시트에 표시할 사람이 읽는 이름.
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .copilot: return "Copilot"
        case .grok: return "Grok"
        case .cursor: return "Cursor"
        case .openrouter: return "OpenRouter"
        case .deepseek: return "DeepSeek"
        case .poe: return "Poe"
        case .elevenlabs: return "ElevenLabs"
        }
    }

    /// 카드 배지/링 색상에 쓰는 SF Symbol 이름.
    var symbolName: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .copilot: return "curlybraces"
        case .grok: return "x.square.fill"
        case .cursor: return "cursorarrow.rays"
        case .openrouter: return "arrow.triangle.branch"
        case .deepseek: return "brain"
        case .poe: return "bubble.left.and.bubble.right"
        case .elevenlabs: return "waveform"
        }
    }

    /// 브랜드 색상.
    var accentColor: Color {
        switch self {
        case .claude: return .orange
        case .codex: return .green
        case .copilot: return .teal
        case .grok: return .gray
        case .cursor: return .blue
        case .openrouter: return .mint
        case .deepseek: return .pink
        case .poe: return .indigo
        case .elevenlabs: return .purple
        }
    }

    /// 터미널 카드에서 provider를 나타내는 짧은 텍스트 태그.
    var terminalTag: String {
        switch self {
        case .claude: return "[C]"
        case .codex:  return "[X]"
        case .copilot: return "[cp]"
        case .grok: return "[gr]"
        case .cursor: return "[cr]"
        case .openrouter: return "[or]"
        case .deepseek: return "[ds]"
        case .poe: return "[P]"
        case .elevenlabs: return "[11]"
        }
    }

    /// 터미널 팔레트 기준 provider 구분색(태그/타이틀 강조용).
    var terminalColor: Color {
        switch self {
        case .claude: return Term.yellow
        case .codex:  return Term.cyan
        case .copilot: return Term.magenta
        case .grok: return Term.fg
        case .cursor: return Term.blue
        case .openrouter: return Term.green
        case .deepseek: return Term.pink
        case .poe: return Term.teal
        case .elevenlabs: return Term.orange
        }
    }

    /// 이 provider의 로그인/인증 방식. `AddAgentSheet`가 이 값으로 UI를 분기한다.
    var authKind: AuthKind {
        switch self {
        case .claude, .grok: return .oauthBrowser
        case .codex: return .oauthCode
        case .copilot, .cursor: return .oauthDeviceFlow
        case .openrouter, .deepseek, .poe, .elevenlabs: return .apiKey
        }
    }

    /// 이 provider가 보여주는 사용량의 성격(구독 잔여 vs 개발자 API 크레딧).
    var usageCategory: UsageCategory {
        switch self {
        // ElevenLabs=구독 문자 할당량, Copilot=구독 프리미엄 요청, Grok=구독 주간 사용량 풀,
        // Cursor=구독 월간 사용량 풀, Poe=구독 컴퓨트 포인트 잔액.
        case .claude, .codex, .copilot, .grok, .cursor, .poe, .elevenlabs: return .subscription
        // 개발자 API 선불 크레딧 잔액.
        case .openrouter, .deepseek: return .apiCredit
        }
    }

    /// apiKey 방식일 때 "키 발급 페이지" 안내 링크. 그 외에는 nil.
    var apiKeyURL: URL? {
        switch self {
        case .claude, .codex, .copilot, .grok, .cursor: return nil
        case .openrouter: return URL(string: "https://openrouter.ai/settings/keys")
        case .deepseek: return URL(string: "https://platform.deepseek.com/api_keys")
        case .poe: return URL(string: "https://poe.com/api_key")
        case .elevenlabs: return URL(string: "https://elevenlabs.io/app/settings/api-keys")
        }
    }

    /// 사람이 열어 볼 수 있는 공식 서비스 상태 페이지. 상세 화면의 [status ↗] 링크 대상.
    var statusPageURL: URL? {
        switch self {
        case .claude:     return URL(string: "https://status.claude.com")
        case .codex:      return URL(string: "https://status.openai.com")
        case .copilot:    return URL(string: "https://www.githubstatus.com")
        case .grok:       return URL(string: "https://status.x.ai")
        case .cursor:     return URL(string: "https://status.cursor.com")
        case .openrouter: return URL(string: "https://status.openrouter.ai")
        case .deepseek:   return URL(string: "https://status.deepseek.com")
        case .poe:        return URL(string: "https://status.poe.com")
        case .elevenlabs: return URL(string: "https://status.elevenlabs.io")
        }
    }

    /// 서비스 운영 상태를 자동 조회할 공개 JSON 엔드포인트(+플랫폼). 없으면 nil.
    /// nil인 provider(OpenRouter=turbo-stream 전용이라 머신리더블 엔드포인트 없음,
    /// Grok=status.x.ai가 Cloudflare로 자동 조회를 막음)는
    /// 메인 목록에 상태를 표시하지 않고, 상세에서만 "알 수 없음"으로 표기한다.
    var statusSource: ServiceStatusSource? {
        func atlassian(_ host: String) -> ServiceStatusSource {
            ServiceStatusSource(platform: .atlassian,
                                jsonURL: URL(string: "https://\(host)/api/v2/components.json")!)
        }
        switch self {
        // Atlassian Statuspage — /api/v2/components.json 공통 스키마.
        case .claude:     return atlassian("status.claude.com")
        case .codex:      return atlassian("status.openai.com")
        case .copilot:    return atlassian("www.githubstatus.com")
        case .cursor:     return atlassian("status.cursor.com")
        // status.deepseek.com은 지역 DNS 제한으로 해석 실패할 수 있어, 전 세계에서
        // 뜨는 원 호스트를 직접 조회한다(동일 페이지).
        case .deepseek:   return atlassian("deepseek.statuspage.io")
        case .poe:        return atlassian("status.poe.com")
        case .elevenlabs: return atlassian("status.elevenlabs.io")
        // 신뢰할 만한 머신리더블 엔드포인트 없음.
        case .openrouter, .grok: return nil
        }
    }
}

/// 사용자가 추가한 에이전트 항목. 리스트의 한 행에 대응한다.
/// 토큰 자체는 Keychain에 저장하고, 여기에는 식별 정보만 보관한다.
struct Agent: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let provider: AgentProvider
    /// 로그인 계정 표시용 (플랜명/이메일 등). 없을 수 있다.
    var accountLabel: String?

    init(id: UUID = UUID(), provider: AgentProvider, accountLabel: String? = nil) {
        self.id = id
        self.provider = provider
        self.accountLabel = accountLabel
    }
}
