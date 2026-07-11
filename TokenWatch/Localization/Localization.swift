//
//  Localization.swift
//  TokenWatch
//
//  앱 내 언어 전환(한국어/영어) 지원. 터미널 스타일의 영어 UI 크롬(예: [done],
//  SETTINGS, keep screen on 등)은 두 언어에서 동일하게 유지하고, 자연어 문장
//  (안내/다이얼로그/페이스/에러 등)만 선택 언어에 맞춰 바꾼다.
//
//  - 뷰: 각 뷰가 @AppStorage("tokenwatch.language")를 읽어 `loc`(L10n)를 만든다 →
//    언어를 바꾸면 즉시 다시 그려진다.
//  - 뷰 밖(네트워크/모델): currentLang()로 현재 언어를 스레드 안전하게 읽는다.
//

import Foundation
import SwiftUI

/// UserDefaults에 저장되는 언어 설정 키.
let appLanguageStorageKey = "tokenwatch.language"

/// 사용자가 설정에서 고르는 UI 언어.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case korean
    case english

    var id: String { rawValue }

    /// .system을 실제 표시 언어로 해석한다(기기 언어 기준).
    var resolved: Lang {
        switch self {
        case .korean:  return .ko
        case .english: return .en
        case .system:
            let pref = Locale.preferredLanguages.first ?? "en"
            return pref.hasPrefix("ko") ? .ko : .en
        }
    }

    /// 설정 세그먼트에 표시할 라벨(선택 언어와 무관하게 각 언어의 자기 이름).
    var segmentLabel: String {
        switch self {
        case .system:  return "auto"
        case .korean:  return "한국어"
        case .english: return "English"
        }
    }
}

/// 실제 렌더링 언어(해석 완료된 값).
enum Lang: Sendable { case ko, en }

/// 뷰 밖(네트워크/모델 등 SwiftUI 환경에 접근할 수 없는 곳)에서 현재 언어를
/// 스레드 안전하게 읽는다. UserDefaults/Locale 모두 스레드 안전.
func currentLang() -> Lang {
    let raw = UserDefaults.standard.string(forKey: appLanguageStorageKey) ?? ""
    return (AppLanguage(rawValue: raw) ?? .system).resolved
}

/// 선택 언어에 대한 문자열 카탈로그. 값 타입이라 뷰에서 매번 새로 만들어도 저렴하다.
struct L10n: Sendable {
    let lang: Lang

    // MARK: 메인 화면(ContentView)
    var a11ySettings: String { lang == .ko ? "설정" : "Settings" }
    var a11yRefresh: String  { lang == .ko ? "새로고침" : "Refresh" }
    var menuRefresh: String  { lang == .ko ? "새로고침" : "Refresh" }
    var menuDelete: String   { lang == .ko ? "삭제" : "Delete" }
    var a11yMoveUp: String   { lang == .ko ? "위로 이동" : "Move up" }
    var a11yMoveDown: String { lang == .ko ? "아래로 이동" : "Move down" }

    // MARK: 설정(SettingsSheet)
    var settingsRefreshHelp: String {
        lang == .ko ? "화면이 켜져 있을 때만 갱신. 너무 짧으면 429 제한에 걸릴 수 있습니다. 창이 리셋되는 시각에는 한 번 더 갱신합니다."
                    : "Refreshes only while the screen is on. Too short may hit the 429 rate limit. An extra refresh runs when a window resets."
    }
    /// Auto 모드 설명 + 현재 유효 간격(예: "60s") 표기.
    func settingsRefreshAutoHelp(_ current: String) -> String {
        lang == .ko ? "auto: 사용량이 빠르게 오르면 간격을 줄이고, 멈추면 늘립니다(30초~10분). 현재 \(current)"
                    : "auto: shortens the interval while usage climbs and relaxes it when idle (30s–10m). now \(current)"
    }
    var settingsScreenHelp: String {
        lang == .ko ? "켜면 앱을 보는 동안 화면이 꺼지지 않습니다."
                    : "When on, the screen stays awake while you view the app."
    }
    var settingsHideUnusedHelp: String {
        lang == .ko ? "사용률이 0%인(전혀 쓰지 않은) 그래프를 목록·상세에서 숨깁니다."
                    : "Hides usage graphs sitting at 0% from the list and detail."
    }
    var settingsHeartbeatHelp: String {
        lang == .ko ? "'$ watching …' 뒤 커서를 언더바 대신 하트로 표시합니다."
                    : "Shows a heart instead of the underscore cursor after '$ watching …'."
    }
    var settingsHeartbeatModeHelp: String {
        lang == .ko ? "usage를 고르면 선택한 그래프의 잔여량을 하트 5칸으로 표시합니다(10%당 반 칸)."
                    : "With usage, the selected graph's remaining amount shows as 5 hearts (half a heart per 10%)."
    }
    var settingsHeartbeatNoGraphs: String {
        lang == .ko ? "추적할 그래프가 없습니다. 먼저 게이지형 에이전트를 추가하세요."
                    : "No graphs to track. Add a gauge-based agent first."
    }
    var settingsLanguageHelp: String {
        lang == .ko ? "시스템 언어를 따르거나 직접 선택합니다."
                    : "Follow the system language or pick one manually."
    }

    // MARK: 상세(AgentDetailView)
    var a11yBack: String           { lang == .ko ? "뒤로" : "Back" }
    var logoutConfirmTitle: String { lang == .ko ? "로그아웃하시겠어요?" : "Log out?" }
    var logout: String             { lang == .ko ? "로그아웃" : "Log out" }
    var cancel: String             { lang == .ko ? "취소" : "Cancel" }
    func logoutMessage(provider: String) -> String {
        lang == .ko ? "\(provider) 계정의 저장된 토큰이 이 기기에서 삭제됩니다."
                    : "The saved token for your \(provider) account will be removed from this device."
    }
    var checking: String    { lang == .ko ? "확인 중…" : "Checking…" }
    var unavailable: String { lang == .ko ? "정보 없음" : "No info" }
    var usageLegend: String {
        lang == .ko ? "= 현재 시각 · 채움이 이 선보다 앞서면 시간보다 빠른 소비"
                    : "= current time · fill past this line means faster-than-time usage"
    }
    /// "미사용 창 숨김" 설정으로 모든 창이 숨겨졌을 때의 안내(카드·상세 공용).
    var usageAllUnusedHidden: String {
        lang == .ko ? "미사용(0%) 창은 숨김" : "unused (0%) windows hidden"
    }

    func paceAhead(_ p: Int) -> String { lang == .ko ? "↑ 시간 대비 \(p)%p 빠름" : "↑ \(p)%p ahead of pace" }
    func paceUnder(_ p: Int) -> String { lang == .ko ? "↓ 시간 대비 \(p)%p 여유" : "↓ \(p)%p under pace" }
    var paceEven: String               { lang == .ko ? "≈ 시간과 비슷한 속도" : "≈ on pace with time" }

    /// 소진 예상 시점(상대). 일/시간/분 중 큰 단위 위주로 표기.
    func depletionETA(days d: Int, hours h: Int, minutes m: Int) -> String {
        switch lang {
        case .ko:
            if d > 0 { return "약 \(d)일 \(h)시간 후" }
            if h > 0 { return "약 \(h)시간 \(m)분 후" }
            return "약 \(max(1, m))분 후"
        case .en:
            if d > 0 { return "in ~\(d)d \(h)h" }
            if h > 0 { return "in ~\(h)h \(m)m" }
            return "in ~\(max(1, m))m"
        }
    }
    func depletionWarning(_ eta: String) -> String {
        lang == .ko ? "이 속도면 리셋 전 소진 예상 (\(eta))"
                    : "At this rate, will run out before reset (\(eta))"
    }

    // MARK: 게이지 접근성(TerminalGauge)
    func a11yUsed(_ pct: Int) -> String { lang == .ko ? "\(pct)% 사용" : "\(pct)% used" }

    // MARK: 사용량 창 리셋 표기(UsageWindow+Display)
    var resetDone: String { lang == .ko ? "리셋됨" : "reset" }

    /// 리셋 정확 시각. 세션=시각만, 주간=날짜+시각.
    func resetExact(_ date: Date, kind: WindowKind) -> String {
        let f = DateFormatter()
        f.locale = dateLocale
        switch (lang, kind) {
        case (.ko, .session): f.dateFormat = "a h:mm"
        case (.ko, .weekly):  f.dateFormat = "M월 d일 a h:mm"
        case (.en, .session): f.dateFormat = "h:mm a"
        case (.en, .weekly):  f.dateFormat = "MMM d, h:mm a"
        }
        return f.string(from: date)
    }

    /// 리셋까지 남은 시간. 세션=시·분, 주간=일·시간.
    func resetRemaining(kind: WindowKind, days: Int, hours: Int, minutes: Int) -> String {
        switch kind {
        case .session:
            switch lang {
            case .ko: return hours > 0 ? "\(hours)시간 \(minutes)분 남음" : "\(minutes)분 남음"
            case .en: return hours > 0 ? "\(hours)h \(minutes)m left" : "\(minutes)m left"
            }
        case .weekly:
            switch lang {
            case .ko: return days > 0 ? "\(days)일 \(hours)시간 남음" : "\(hours)시간 남음"
            case .en: return days > 0 ? "\(days)d \(hours)h left" : "\(hours)h left"
            }
        }
    }

    /// "리셋 <시각> · <남은 시간>" 한 줄 요약.
    func resetLine(exact: String, remain: String?) -> String {
        switch lang {
        case .ko: return remain.map { "리셋 \(exact) · \($0)" } ?? "리셋 \(exact)"
        case .en: return remain.map { "resets \(exact) · \($0)" } ?? "resets \(exact)"
        }
    }

    // MARK: 에러(ProviderDispatch · OAuth 등)
    var errAuthExpired: String { lang == .ko ? "인증이 만료되었습니다. 다시 로그인해 주세요." : "Authentication expired. Please log in again." }
    var errRateLimited: String { lang == .ko ? "요청이 많아 잠시 대기 중입니다." : "Too many requests. Waiting a moment." }
    func errHTTP(_ code: Int) -> String { lang == .ko ? "사용량 조회 실패 (HTTP \(code))." : "Failed to fetch usage (HTTP \(code))." }
    func errDecode(_ m: String) -> String { lang == .ko ? "응답 해석 실패: \(m)" : "Failed to read response: \(m)" }
    var errNoWindows: String { lang == .ko ? "표시할 사용량 창이 없습니다." : "No usage windows to display." }
    func errRateLimitedRetry(_ mins: Int) -> String {
        lang == .ko ? "요청이 많아 잠시 대기 중입니다. 약 \(mins)분 후 재시도합니다."
                    : "Too many requests. Retrying in ~\(mins) min."
    }
    func errTokenExchange(_ m: String) -> String { lang == .ko ? "토큰 교환 실패: \(m)" : "Token exchange failed: \(m)" }
    func errTokenRefresh(_ m: String) -> String { lang == .ko ? "토큰 갱신 실패: \(m)" : "Token refresh failed: \(m)" }
    var errNotAuthenticated: String { lang == .ko ? "로그인이 필요합니다." : "Login required." }
    func errParse(_ m: String) -> String { lang == .ko ? "응답 파싱 실패: \(m)" : "Failed to parse response: \(m)" }
    /// 아직 구현되지 않은 인증 방식(sessionCapture)을 고른 경우.
    var errAuthMethodUnavailable: String {
        lang == .ko ? "이 로그인 방식은 곧 지원됩니다." : "This sign-in method is coming soon."
    }

    // MARK: 디바이스 플로우(GitHub Copilot 등)
    var deviceFlowRequesting: String { lang == .ko ? "코드 요청 중…" : "requesting code…" }
    var deviceFlowPrompt: String {
        lang == .ko ? "브라우저에서 아래 코드를 입력해 인증하세요."
                    : "Enter this code in your browser to authorize."
    }
    var deviceFlowOpen: String { lang == .ko ? "[ 브라우저 열기 ↗ ]" : "[ open browser ↗ ]" }
    var deviceFlowWaiting: String { lang == .ko ? "인증 대기 중…" : "waiting for authorization…" }
    var deviceFlowExpired: String {
        lang == .ko ? "코드가 만료되었습니다. 다시 시도해 주세요." : "The code expired. Please try again."
    }
    var deviceFlowDenied: String { lang == .ko ? "인증이 거부되었습니다." : "Authorization was denied." }

    // MARK: Codex 사용량 라벨
    var codexAdditionalLimit: String { lang == .ko ? "추가 한도" : "Additional limit" }

    // MARK: 사용량 성격(UsageCategory) — 구독 잔여 vs 개발자 API 크레딧
    func usageCategoryLabel(_ category: UsageCategory) -> String {
        switch category {
        case .subscription: return lang == .ko ? "구독 사용량" : "subscription"
        case .apiCredit:    return lang == .ko ? "API 크레딧" : "API credit"
        }
    }

    // MARK: 날짜/시간 포맷
    var dateLocale: Locale { Locale(identifier: lang == .ko ? "ko_KR" : "en_US") }

    func relativeTime(_ date: Date, relativeTo now: Date = Date()) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = dateLocale
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }

    func absoluteDateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = dateLocale
        f.dateFormat = lang == .ko ? "M월 d일 a h:mm" : "MMM d, h:mm a"
        return f.string(from: date)
    }
}
