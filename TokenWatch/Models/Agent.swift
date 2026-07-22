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
    /// WKWebView로 로그인 → OAuth 콜백 리다이렉트에서 code를 가로챈다. (Claude/Codex)
    case oauthCode
    /// user code를 발급받아 브라우저에서 승인 → 토큰을 폴링한다. (예: GitHub Copilot)
    case oauthDeviceFlow
    /// WKWebView로 로그인한 뒤 쿠키/로컬스토리지 토큰을 캡처한다. (예: Cursor/Grok)
    case sessionCapture
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

/// 지원하는 AI 에이전트 제공자. Claude/Codex로 시작하지만, 인증 방식(`authKind`)과
/// 사용량 성격(`usageCategory`)을 provider별 메타데이터로 두어 다양한 플랫폼을
/// 같은 방식으로 확장할 수 있게 한다.
enum AgentProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case elevenlabs
    case copilot
    case cursor
    case openrouter
    case deepseek
    case poe
    case fal
    case stability
    case recraft
    case luma
    case runway
    case did
    case heygen
    case leonardo
    case grok
    case windsurf

    var id: String { rawValue }

    /// 리스트/시트에 표시할 사람이 읽는 이름.
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .elevenlabs: return "ElevenLabs"
        case .copilot: return "Copilot"
        case .cursor: return "Cursor"
        case .openrouter: return "OpenRouter"
        case .deepseek: return "DeepSeek"
        case .poe: return "Poe"
        case .fal: return "Fal"
        case .stability: return "Stability"
        case .recraft: return "Recraft"
        case .luma: return "Luma"
        case .runway: return "Runway"
        case .did: return "D-ID"
        case .heygen: return "HeyGen"
        case .leonardo: return "Leonardo"
        case .grok: return "Grok"
        case .windsurf: return "Windsurf"
        }
    }

    /// 카드 배지/링 색상에 쓰는 SF Symbol 이름.
    var symbolName: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .elevenlabs: return "waveform"
        case .copilot: return "curlybraces"
        case .cursor: return "cursorarrow.rays"
        case .openrouter: return "arrow.triangle.branch"
        case .deepseek: return "brain"
        case .poe: return "bubble.left.and.bubble.right"
        case .fal: return "bolt.horizontal.fill"
        case .stability: return "square.stack.3d.up"
        case .recraft: return "paintbrush.pointed.fill"
        case .luma: return "video.fill"
        case .runway: return "film.fill"
        case .did: return "person.crop.rectangle.fill"
        case .heygen: return "person.wave.2.fill"
        case .leonardo: return "paintpalette.fill"
        case .grok: return "x.square.fill"
        case .windsurf: return "wind"
        }
    }

    /// 브랜드 색상.
    var accentColor: Color {
        switch self {
        case .claude: return .orange
        case .codex: return .green
        case .elevenlabs: return .purple
        case .copilot: return .teal
        case .cursor: return .blue
        case .openrouter: return .mint
        case .deepseek: return .pink
        case .poe: return .indigo
        case .fal: return .purple
        case .stability: return .indigo
        case .recraft: return .brown
        case .luma: return .cyan
        case .runway: return .orange
        case .did: return .pink
        case .heygen: return .green
        case .leonardo: return .yellow
        case .grok: return .gray
        case .windsurf: return .teal
        }
    }

    /// 터미널 카드에서 provider를 나타내는 짧은 텍스트 태그.
    var terminalTag: String {
        switch self {
        case .claude: return "[C]"
        case .codex:  return "[X]"
        case .elevenlabs: return "[11]"
        case .copilot: return "[cp]"
        case .cursor: return "[cr]"
        case .openrouter: return "[or]"
        case .deepseek: return "[ds]"
        case .poe: return "[P]"
        case .fal: return "[fl]"
        case .stability: return "[st]"
        case .recraft: return "[rc]"
        case .luma: return "[lm]"
        case .runway: return "[rw]"
        case .did: return "[dd]"
        case .heygen: return "[hg]"
        case .leonardo: return "[le]"
        case .grok: return "[gr]"
        case .windsurf: return "[ws]"
        }
    }

    /// 터미널 팔레트 기준 provider 구분색(태그/타이틀 강조용).
    var terminalColor: Color {
        switch self {
        case .claude: return Term.yellow
        case .codex:  return Term.cyan
        case .elevenlabs: return Term.orange
        case .copilot: return Term.magenta
        case .cursor: return Term.blue
        case .openrouter: return Term.green
        case .deepseek: return Term.pink
        case .poe: return Term.teal
        case .fal: return Term.magenta
        case .stability: return Term.green
        case .recraft: return Term.yellow
        case .luma: return Term.cyan
        case .runway: return Term.orange
        case .did: return Term.pink
        case .heygen: return Term.blue
        case .leonardo: return Term.yellow
        case .grok: return Term.fg
        case .windsurf: return Term.teal
        }
    }

    /// 이 provider의 로그인/인증 방식. `AddAgentSheet`가 이 값으로 UI를 분기한다.
    var authKind: AuthKind {
        switch self {
        case .claude, .codex: return .oauthCode
        case .elevenlabs, .openrouter, .deepseek, .poe, .fal, .stability, .recraft,
             .luma, .runway, .did, .heygen, .leonardo: return .apiKey
        case .copilot: return .oauthDeviceFlow
        case .cursor, .grok, .windsurf: return .sessionCapture
        }
    }

    /// 이 provider가 보여주는 사용량의 성격(구독 잔여 vs 개발자 API 크레딧).
    var usageCategory: UsageCategory {
        switch self {
        // ElevenLabs=구독 문자 할당량, Copilot=구독 프리미엄 요청, Cursor=구독 빠른 요청,
        // Poe=구독 컴퓨트 포인트 잔액.
        case .claude, .codex, .elevenlabs, .copilot, .cursor, .poe, .grok, .windsurf: return .subscription
        // 개발자 API 선불 크레딧 잔액.
        case .openrouter, .deepseek, .fal, .stability, .recraft,
             .luma, .runway, .did, .heygen, .leonardo: return .apiCredit
        }
    }

    /// apiKey 방식일 때 "키 발급 페이지" 안내 링크. 그 외에는 nil.
    var apiKeyURL: URL? {
        switch self {
        case .claude, .codex, .copilot, .cursor, .grok, .windsurf: return nil
        case .elevenlabs: return URL(string: "https://elevenlabs.io/app/settings/api-keys")
        case .openrouter: return URL(string: "https://openrouter.ai/settings/keys")
        case .deepseek: return URL(string: "https://platform.deepseek.com/api_keys")
        case .poe: return URL(string: "https://poe.com/api_key")
        case .fal: return URL(string: "https://fal.ai/dashboard/keys")
        case .stability: return URL(string: "https://platform.stability.ai/account/keys")
        case .recraft: return URL(string: "https://www.recraft.ai/profile/api")
        case .luma: return URL(string: "https://lumalabs.ai/dream-machine/api/keys")
        case .runway: return URL(string: "https://dev.runwayml.com/")
        case .did: return URL(string: "https://studio.d-id.com/account-settings")
        case .heygen: return URL(string: "https://app.heygen.com/settings")
        case .leonardo: return URL(string: "https://app.leonardo.ai/api-access")
        }
    }

    /// 사람이 열어 볼 수 있는 공식 서비스 상태 페이지. 상세 화면의 [status ↗] 링크 대상.
    /// Leonardo는 공식 상태 페이지가 없어 nil(장애 공지를 Intercom/X로만 안내).
    var statusPageURL: URL? {
        switch self {
        case .claude:     return URL(string: "https://status.claude.com")
        case .codex:      return URL(string: "https://status.openai.com")
        case .copilot:    return URL(string: "https://www.githubstatus.com")
        case .cursor:     return URL(string: "https://status.cursor.com")
        case .windsurf:   return URL(string: "https://status.windsurf.com")
        case .deepseek:   return URL(string: "https://status.deepseek.com")
        case .poe:        return URL(string: "https://status.poe.com")
        case .elevenlabs: return URL(string: "https://status.elevenlabs.io")
        case .stability:  return URL(string: "https://status.stability.ai")
        case .runway:     return URL(string: "https://status.runwayml.com")
        case .did:        return URL(string: "https://status.d-id.com")
        case .heygen:     return URL(string: "https://status.heygen.com")
        case .fal:        return URL(string: "https://status.fal.ai")
        case .recraft:    return URL(string: "https://status.recraft.ai")
        case .luma:       return URL(string: "https://status.lumalabs.ai")
        case .openrouter: return URL(string: "https://status.openrouter.ai")
        case .grok:       return URL(string: "https://status.x.ai")
        case .leonardo:   return nil
        }
    }

    /// 서비스 운영 상태를 자동 조회할 공개 JSON 엔드포인트(+플랫폼). 없으면 nil.
    /// nil인 provider(OpenRouter=turbo-stream 전용, Grok=Cloudflare 봇 차단,
    /// Leonardo=상태 페이지 없음)는 메인 목록에 상태를 표시하지 않고, 상세에서만
    /// "알 수 없음"으로 표기한다.
    var statusSource: ServiceStatusSource? {
        func atlassian(_ host: String) -> ServiceStatusSource {
            ServiceStatusSource(platform: .atlassian,
                                jsonURL: URL(string: "https://\(host)/api/v2/components.json")!)
        }
        func instatus(_ host: String) -> ServiceStatusSource {
            ServiceStatusSource(platform: .instatus,
                                jsonURL: URL(string: "https://\(host)/v2/components.json")!)
        }
        switch self {
        // Atlassian Statuspage — /api/v2/components.json 공통 스키마.
        case .claude:     return atlassian("status.claude.com")
        case .codex:      return atlassian("status.openai.com")
        case .copilot:    return atlassian("www.githubstatus.com")
        case .cursor:     return atlassian("status.cursor.com")
        case .windsurf:   return atlassian("status.windsurf.com")
        // status.deepseek.com은 지역 DNS 제한으로 해석 실패할 수 있어, 전 세계에서
        // 뜨는 원 호스트를 직접 조회한다(동일 페이지).
        case .deepseek:   return atlassian("deepseek.statuspage.io")
        case .poe:        return atlassian("status.poe.com")
        case .elevenlabs: return atlassian("status.elevenlabs.io")
        case .stability:  return atlassian("status.stability.ai")
        case .runway:     return atlassian("status.runwayml.com")
        case .did:        return atlassian("status.d-id.com")
        case .heygen:     return atlassian("status.heygen.com")
        // Instatus — /v2/components.json. 커스텀 도메인은 리다이렉트를 피해 원 호스트를 조회.
        case .fal:        return instatus("status.fal.ai")
        case .recraft:    return instatus("recraft.instatus.com")
        // Better Stack — /index.json → included[status_page_resource].attributes.status.
        case .luma:       return ServiceStatusSource(platform: .betterstack,
                                                     jsonURL: URL(string: "https://status.lumalabs.ai/index.json")!)
        // 신뢰할 만한 머신리더블 엔드포인트 없음.
        case .openrouter, .grok, .leonardo: return nil
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
