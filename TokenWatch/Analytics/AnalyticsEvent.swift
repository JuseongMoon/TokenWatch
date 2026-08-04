//
//  AnalyticsEvent.swift
//  TokenWatch
//
//  분석 이벤트의 타입세이프 정의(docs/ga-analytics-plan.md §4와 1:1). Firebase를 모른다 —
//  이름/파라미터로만 변환되고 실제 전송은 AnalyticsService(유일한 Firebase 접점)가 한다.
//  파라미터에는 provider rawValue·열거 문자열·정수만 허용한다. 계정 라벨/이메일/토큰/
//  원문 에러 메시지/사용률 수치는 어떤 경로로도 넣지 않는다.
//

import Foundation

/// 로그인 퍼널에서 실패/이탈이 일어난 단계.
enum LoginStage: String, Sendable {
    case authorize                          // 웹뷰 인가 페이지 진행 중
    case stateMismatch = "state_mismatch"   // CSRF state 불일치
    case exchange                           // code → token 교환
    case devicePoll = "device_poll"         // device flow 코드 발급·승인 폴링
    case apiKeyEntry = "api_key_entry"      // API 키 입력 화면
    case keychain                           // Keychain 저장 실패
}

/// usage 조회 실패의 기계 판독 사유. 원문(현지화된) 에러 메시지 대신 이 값만 전송한다.
enum FetchErrorReason: String, Sendable {
    case auth                               // 인증 만료/refresh 실패 → 재로그인 필요
    case rateLimit = "rate_limit"
    case http4xx = "http_4xx"
    case http5xx = "http_5xx"
    case network
    case parse
    case empty                              // 200이지만 창 0개 — 스키마 변경 신호
    case other
}

/// 수동 screen_view 대상 화면(자동 수집은 Info.plist에서 꺼 둠).
enum ScreenName: String, Sendable {
    case main
    case addAgent = "add_agent"
    case agentDetail = "agent_detail"
    case settings
    case workHours = "work_hours"

    /// screen_class로 함께 보낼 뷰 이름. 생략하면 SDK가 UIHostingController의 제네릭
    /// 타입명(274자)을 채워 넣는데, 이는 100자 제한을 넘겨 이벤트에 오류 파라미터가 붙고
    /// 시트 화면에서는 screen_name까지 통째로 유실된다. 그래서 직접 짧은 이름을 넘긴다.
    var screenClass: String {
        switch self {
        case .main: return "ContentView"
        case .addAgent: return "AddAgentSheet"
        case .agentDetail: return "AgentDetailView"
        case .settings: return "SettingsSheet"
        case .workHours: return "WorkHoursEditor"
        }
    }
}

/// 앱이 기록하는 모든 분석 이벤트.
enum AnalyticsEvent {
    // 활성화 퍼널
    case loginStart(provider: AgentProvider)
    case loginSuccess(provider: AgentProvider, agentsTotal: Int)
    case loginFail(provider: AgentProvider, stage: LoginStage, code: String)
    case loginAbandon(provider: AgentProvider, stage: LoginStage)
    /// 설치 후 1회 — 첫 에이전트의 첫 정상 스냅샷 표시(진짜 "aha" 시점). GA4 키 이벤트.
    case activationComplete(provider: AgentProvider)
    // 데모 퍼널
    case demoStart(source: DemoSource)
    case demoEnd
    // 참여
    case screenView(ScreenName, provider: AgentProvider? = nil)
    case refreshManual(source: RefreshSource)
    case settingChange(setting: String, value: String)
    case notificationOpen(kind: NotificationKind)
    case agentRemove(provider: AgentProvider, agentsTotal: Int)
    // 신뢰성(정상↔에러 전이 시에만 — AgentStore가 보장)
    case usageFetchError(provider: AgentProvider, reason: FetchErrorReason)
    case usageFetchRecover(provider: AgentProvider)

    enum DemoSource: String, Sendable {
        case emptyList = "empty_list"
        case settings
    }

    enum RefreshSource: String, Sendable {
        case pullList = "pull_list"
        case pullDetail = "pull_detail"
        case button
        case contextMenu = "context_menu"
    }

    enum NotificationKind: String, Sendable {
        case resetScheduled = "reset_scheduled"   // 예약형(정시 리셋)
        case resetSurprise = "reset_surprise"     // 감지형(예정보다 이른 리셋)
    }

    /// GA4 이벤트 이름(snake_case, 40자 이내). screen_view는 GA4 예약 이름을 그대로 쓴다.
    var name: String {
        switch self {
        case .loginStart: return "login_start"
        case .loginSuccess: return "login_success"
        case .loginFail: return "login_fail"
        case .loginAbandon: return "login_abandon"
        case .activationComplete: return "activation_complete"
        case .demoStart: return "demo_start"
        case .demoEnd: return "demo_end"
        case .screenView: return "screen_view"
        case .refreshManual: return "refresh_manual"
        case .settingChange: return "setting_change"
        case .notificationOpen: return "notification_open"
        case .agentRemove: return "agent_remove"
        case .usageFetchError: return "usage_fetch_error"
        case .usageFetchRecover: return "usage_fetch_recover"
        }
    }

    var parameters: [String: Any] {
        switch self {
        case .loginStart(let p):
            return ["provider": p.rawValue, "auth_kind": Self.authKindTag(p)]
        case .loginSuccess(let p, let total):
            return ["provider": p.rawValue, "auth_kind": Self.authKindTag(p), "agents_total": total]
        case .loginFail(let p, let stage, let code):
            return ["provider": p.rawValue, "auth_kind": Self.authKindTag(p),
                    "stage": stage.rawValue, "code": String(code.prefix(40))]
        case .loginAbandon(let p, let stage):
            return ["provider": p.rawValue, "stage": stage.rawValue]
        case .activationComplete(let p):
            return ["provider": p.rawValue]
        case .demoStart(let source):
            return ["source": source.rawValue]
        case .demoEnd:
            return [:]
        case .screenView(let screen, let provider):
            var params: [String: Any] = ["screen_name": screen.rawValue,
                                         "screen_class": screen.screenClass]
            if let provider { params["provider"] = provider.rawValue }
            return params
        case .refreshManual(let source):
            return ["source": source.rawValue]
        case .settingChange(let setting, let value):
            return ["setting": setting, "value": value]
        case .notificationOpen(let kind):
            return ["kind": kind.rawValue]
        case .agentRemove(let p, let total):
            return ["provider": p.rawValue, "agents_total": total]
        case .usageFetchError(let p, let reason):
            return ["provider": p.rawValue, "reason": reason.rawValue]
        case .usageFetchRecover(let p):
            return ["provider": p.rawValue]
        }
    }

    /// 데모 모드에서 차단할 provider 차원 이벤트인지. 표본 데이터가 실제 provider 지표를
    /// 오염시키지 않도록 AnalyticsService가 이 값으로 거른다(데모 격리 원칙과 일관).
    var isProviderScoped: Bool {
        switch self {
        case .screenView, .settingChange, .demoStart, .demoEnd, .notificationOpen:
            return false
        default:
            return true
        }
    }

    private static func authKindTag(_ provider: AgentProvider) -> String {
        switch provider.authKind {
        case .oauthCode: return "oauth"
        case .oauthDeviceFlow: return "device"
        case .apiKey: return "api_key"
        }
    }
}

extension AgentProvider {
    /// 유저 속성 `providers`용 축약 태그 — GA4 속성값 36자 제한 대응(7종 전부여도 17자).
    var analyticsShortTag: String {
        switch self {
        case .claude: return "c"
        case .codex: return "x"
        case .copilot: return "cp"
        case .openrouter: return "or"
        case .deepseek: return "ds"
        case .poe: return "p"
        case .elevenlabs: return "11"
        }
    }
}
