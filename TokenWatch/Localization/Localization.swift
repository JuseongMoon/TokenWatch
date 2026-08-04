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
        lang == .ko ? "auto: 사용량이 빠르게 오르면 간격을 줄이고, 멈추면 늘립니다(10초~5분). 현재 \(current)"
                    : "auto: shortens the interval while usage climbs and relaxes it when idle (10s–5m). now \(current)"
    }
    var settingsScreenHelp: String {
        lang == .ko ? "켜면 앱을 보는 동안 화면이 꺼지지 않습니다."
                    : "When on, the screen stays awake while you view the app."
    }
    var settingsHideUnusedHelp: String {
        lang == .ko ? "사용률이 0%인(전혀 쓰지 않은) 그래프를 목록·상세에서 숨깁니다."
                    : "Hides usage graphs sitting at 0% from the list and detail."
    }
    var settingsGaugeCritterHelp: String {
        lang == .ko ? "사용률 100%가 된 게이지 위를 픽셀 슬라임이 통통 튀며 지나갑니다."
                    : "A pixel slime hops across any gauge that hits 100%."
    }

    // MARK: 업무시간(WorkHours)
    var settingsWorkHoursHelp: String {
        lang == .ko ? "주간 그래프의 현재 시각 세로선이 설정한 업무시간에만 흐릅니다. 비워 두면 한 주 내내 균일하게 흐릅니다."
                    : "The current-time line on weekly graphs advances only during your work hours. Leave empty to flow evenly across the whole week."
    }
    var workHoursButton: String { lang == .ko ? "[ 업무시간 설정 ]" : "[ set work hours ]" }
    var workHoursNotSet: String { lang == .ko ? "설정 안 됨" : "not set" }
    /// 설정 버튼 옆 요약(예: "주 40시간").
    func workHoursSummary(hours h: Int) -> String {
        lang == .ko ? "주 \(h)시간" : "\(h) h/week"
    }
    /// 모달 카드 안내.
    var workHoursEditorHelp: String {
        lang == .ko ? "블록을 탭하면 켜고/끄고, 누른 채 드래그하면 범위를 한 번에 칠합니다."
                    : "Tap a block to toggle it; press and drag to paint a range at once."
    }
    var workHoursSave: String   { lang == .ko ? "[ 저장 ]" : "[ save ]" }
    var workHoursCancel: String { lang == .ko ? "[ 취소 ]" : "[ cancel ]" }
    var workHoursClear: String  { lang == .ko ? "[ 지우기 ]" : "[ clear ]" }
    /// 요일 헤더(0=월 … 6=일).
    func weekdayShort(_ i: Int) -> String {
        let ko = ["월", "화", "수", "목", "금", "토", "일"]
        let en = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        guard i >= 0, i < 7 else { return "" }
        return lang == .ko ? ko[i] : en[i]
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
    var settingsHeartbeatMultiHelp: String {
        lang == .ko ? "여러 개를 고르면 남은 비율의 평균을 하트로 표시합니다."
                    : "Pick several and the heart shows the average of their remaining amounts."
    }
    var settingsLanguageHelp: String {
        lang == .ko ? "시스템 언어를 따르거나 직접 선택합니다."
                    : "Follow the system language or pick one manually."
    }

    // MARK: 상세(AgentDetailView)
    var a11yBack: String           { lang == .ko ? "뒤로" : "Back" }
    var a11yStatusPage: String     { lang == .ko ? "서비스 상태 페이지 열기" : "Open service status page" }
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
    func a11yRemaining(_ pct: Int) -> String { lang == .ko ? "\(pct)% 남음" : "\(pct)% left" }
    /// 충전형 게이지가 관측 최고 잔액 기반 추정임을 알리는 안내(상세 화면).
    var creditApproxNote: String {
        lang == .ko ? "총액은 관측된 최고 잔액 기준 추정" : "total estimated from highest observed balance"
    }
    /// 충전형 추정 게이지의 peak 수동 리셋 어피던스.
    var creditResetButton: String  { lang == .ko ? "[재설정]" : "[reset]" }
    var creditResetTitle: String   { lang == .ko ? "게이지 기준 재설정" : "Reset gauge scale" }
    var creditResetConfirm: String { lang == .ko ? "재설정" : "Reset" }
    var creditResetMessage: String {
        lang == .ko ? "현재 잔액을 100%(가득)로 삼아 이 게이지의 기준을 다시 잡습니다. 이상값으로 게이지가 낮게 굳었을 때 사용하세요."
                    : "Re-baselines this gauge, treating the current balance as 100% (full). Use when a spike has frozen the gauge too low."
    }

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

    // MARK: 사용량 리셋 알림(NotificationManager)
    /// 알림 제목 — 어느 에이전트인지. 계정 라벨(이메일/플랜)이 있으면 덧붙인다.
    func notifResetTitle(provider: String, account: String?) -> String {
        guard let a = account, !a.isEmpty else { return provider }
        return "\(provider) · \(a)"
    }
    /// 알림 본문 — 리셋된 창 종류에 따라. 에이전트별로 묶인 뒤 호출된다.
    func notifResetBody(session: Bool, weekly: Bool) -> String {
        switch lang {
        case .ko:
            if session && weekly { return "사용량 한도가 리셋되었습니다. 다시 사용할 수 있어요." }
            if session { return "세션 한도가 리셋되었습니다. 다시 사용할 수 있어요." }
            return "주간 한도가 리셋되었습니다. 다시 사용할 수 있어요."
        case .en:
            if session && weekly { return "Your usage limits have reset — you're good to go." }
            if session { return "Your session limit has reset — you're good to go." }
            return "Your weekly limit has reset — you're good to go."
        }
    }
    /// 에이전트를 못 찾았을 때(삭제 직후 등) 예약 알림 제목 fallback.
    var notifDefaultTitle: String { lang == .ko ? "TokenWatch" : "TokenWatch" }

    // MARK: 알림 설정(SettingsSheet)
    var settingsNotifHelp: String {
        lang == .ko ? "사용량 한도가 리셋되면 알림을 보냅니다. 세션은 5시간마다 리셋되어 자주 올 수 있습니다."
                    : "Notifies you when a usage limit resets. Sessions reset every 5 hours, so they can be frequent."
    }
    var settingsNotifDenied: String {
        lang == .ko ? "알림이 꺼져 있습니다. 아래에서 iOS 설정을 열어 켜세요."
                    : "Notifications are off. Open iOS Settings below to turn them on."
    }
    var settingsNotifOpenSettings: String {
        lang == .ko ? "[ iOS 설정 열기 ↗ ]" : "[ open iOS Settings ↗ ]"
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
    /// 429 백오프 중 캐시된 그래프를 계속 보여줄 때: 재시도 안내 + 아래 그래프가 갱신 정지
    /// 상태임을 함께 알린다(그래프는 이름 아래 이 안내 다음에 그려진다).
    func errRateLimitedRetryStale(_ mins: Int) -> String {
        lang == .ko ? "요청이 많아 대기 중입니다. 약 \(mins)분 후 재시도 · 아래 그래프는 갱신되지 않습니다."
                    : "Too many requests. Retrying in ~\(mins) min · usage below isn't updating."
    }
    func errTokenExchange(_ m: String) -> String { lang == .ko ? "토큰 교환 실패: \(m)" : "Token exchange failed: \(m)" }
    func errTokenRefresh(_ m: String) -> String { lang == .ko ? "토큰 갱신 실패: \(m)" : "Token refresh failed: \(m)" }
    var errNotAuthenticated: String { lang == .ko ? "로그인이 필요합니다." : "Login required." }
    var errStateMismatch: String {
        lang == .ko ? "로그인 응답 검증에 실패했습니다(state 불일치). 다시 시도해 주세요."
                    : "Login response failed verification (state mismatch). Please try again."
    }
    var errKeychainSave: String {
        lang == .ko ? "토큰을 안전 저장소(Keychain)에 저장하지 못했습니다. 다시 시도해 주세요."
                    : "Couldn't save the token to the Keychain. Please try again."
    }
    func errParse(_ m: String) -> String { lang == .ko ? "응답 파싱 실패: \(m)" : "Failed to parse response: \(m)" }

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

    // MARK: 서비스 운영 상태(ServiceHealth)
    func serviceHealthLabel(_ health: ServiceHealth) -> String {
        switch health {
        case .operational: return lang == .ko ? "정상" : "operational"
        case .caution:     return lang == .ko ? "주의" : "caution"
        case .major:       return lang == .ko ? "이상" : "outage"
        case .totalOutage: return lang == .ko ? "전체 이상" : "total outage"
        case .maintenance: return lang == .ko ? "전체 점검중" : "under maintenance"
        case .unknown:     return lang == .ko ? "알 수 없음" : "unknown"
        }
    }

    /// 메인 카드 신호등 배지에 인라인으로 띄우는 점검 표시(전체점검 전용).
    var serviceMaintenanceBadge: String { lang == .ko ? "점검중" : "maintenance" }

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
