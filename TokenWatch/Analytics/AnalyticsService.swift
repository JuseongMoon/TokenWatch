//
//  AnalyticsService.swift
//  TokenWatch
//
//  유일한 Firebase 접점. 게이트 순서: 미구성(plist 없음) → 옵트아웃 → 데모(provider 이벤트).
//  - GoogleService-Info.plist가 번들에 없으면 전부 no-op — plist 미동봉 빌드에서도 안전.
//  - DEBUG 빌드는 -FIRDebugEnabled 실행 인자(DebugView 검증) 때만 수집 — 개발 노이즈 차단.
//  - 옵트아웃(설정 PRIVACY): 기본 ON, 끄면 SDK 수집 자체를 중지하고 래퍼에서도 원천 차단.
//

import Foundation
import FirebaseCore
import FirebaseAnalytics

@MainActor
final class AnalyticsService {
    static let shared = AnalyticsService()

    /// 옵트아웃 설정 키(기본 ON — 키 부재 시 true). SettingsSheet의 @AppStorage와 공유.
    static let enabledKey = "tokenwatch.analyticsEnabled"

    /// 데모 모드 판별 — TokenWatchApp이 실제 AgentStore를 주입한다.
    var isDemo: () -> Bool = { false }

    /// FirebaseApp.configure() 완료 여부. false면 모든 호출이 no-op.
    private var configured = false

    private init() {}

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) == nil
            ? true : UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// 앱 시작 시 1회(AgentStore 생성 전에). plist가 있을 때만 configure하고
    /// 수집 상태를 옵트아웃 설정과 일치시킨다.
    func configure() {
        guard !configured else { return }
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
            debugLog("GoogleService-Info.plist를 번들에서 못 찾음 — 분석 꺼짐")
            return
        }
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-FIRDebugEnabled") else {
            debugLog("DEBUG 빌드인데 -FIRDebugEnabled 인자가 없음 — 분석 꺼짐")
            return
        }
        #endif
        FirebaseApp.configure()
        configured = true
        Analytics.setAnalyticsCollectionEnabled(isEnabled)
        debugLog("Firebase 구성 완료 — 수집 \(isEnabled ? "ON" : "OFF")")
    }

    /// 분석이 켜졌는지/왜 꺼졌는지를 DEBUG 콘솔에 알린다. 게이트가 3중이라
    /// 조용히 꺼져 있을 때 원인을 눈으로 확인할 수단이 필요하다.
    private func debugLog(_ message: String) {
        #if DEBUG
        print("[TokenWatch.Analytics] \(message)")
        #endif
    }

    /// 설정 PRIVACY 토글 반영. 끄면 SDK 수집을 즉시 중지한다.
    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        guard configured else { return }
        Analytics.setAnalyticsCollectionEnabled(enabled)
    }

    func log(_ event: AnalyticsEvent) {
        guard configured, isEnabled else { return }
        let demo = isDemo()
        if event.isProviderScoped, demo { return }
        var params = event.parameters
        // 데모 중 살아남는 이벤트(screen_view 등)에서도 provider 차원은 제거한다.
        if demo { params["provider"] = nil }
        Analytics.logEvent(event.name, parameters: params.isEmpty ? nil : params)
    }

    // MARK: 유저 속성

    /// 에이전트 파생 + 설정 파생 속성 일괄 동기화 — 앱 시작·에이전트 추가/삭제·옵트인 시.
    /// 데모 중에는 표본 목록이 실제 속성을 덮어쓰지 않도록 건너뛴다.
    func syncUserProperties(agents: [Agent]) {
        guard configured, isEnabled, !isDemo() else { return }
        Analytics.setUserProperty("\(agents.count)", forName: "agents_count")
        let tags = agents.map(\.provider.analyticsShortTag).sorted().joined(separator: ",")
        Analytics.setUserProperty(tags.isEmpty ? nil : tags, forName: "providers")
        syncSettingsProperties()
    }

    /// 설정에서 파생되는 속성만 갱신 — 에이전트 목록이 필요 없는 호출부(설정 변경)용.
    /// 설정값 자체는 데모와 무관한 실제 값이므로 데모 게이트를 두지 않는다.
    func syncSettingsProperties() {
        guard configured, isEnabled else { return }
        let d = UserDefaults.standard

        let interval = d.object(forKey: "tokenwatch.refreshInterval") as? Int ?? 60
        setProperty(RefreshInterval(rawValue: interval)?.termLabel ?? "\(interval)s", "refresh_mode")

        let session = d.bool(forKey: NotificationDefaults.sessionKey)
        let weekly = d.object(forKey: NotificationDefaults.weeklyKey) == nil
            ? true : d.bool(forKey: NotificationDefaults.weeklyKey)
        setProperty(session ? (weekly ? "both" : "session") : (weekly ? "weekly" : "none"), "notify")

        let hours = WorkHoursSchedule(encoded: d.string(forKey: workHoursStorageKey) ?? "").onHours
        setProperty(Self.workHoursBucket(hours, enabled: WorkHoursSchedule.isEnabled(in: d)), "work_hours")

        let heartbeat = d.bool(forKey: "tokenwatch.heartbeatCursor")
        let tracking = d.bool(forKey: "tokenwatch.heartbeatTracking")
        setProperty(heartbeat ? (tracking ? "usage" : "heart") : "off", "heartbeat")

        switch AppLanguage(rawValue: d.string(forKey: appLanguageStorageKey) ?? "") ?? .system {
        case .system: setProperty("system", "app_lang")
        case .korean: setProperty("ko", "app_lang")
        case .english: setProperty("en", "app_lang")
        }
    }

    /// 주당 업무시간 → 속성 버킷. 기능이 꺼져 있으면 시간 수와 무관하게 "off"
    /// (토글을 끈 사용자가 시간대를 보존하고 있어도 "실효 없음"으로 보고한다).
    static func workHoursBucket(_ hours: Int, enabled: Bool) -> String {
        guard enabled else { return "off" }
        switch hours {
        case ..<1: return "off"
        case 1...20: return "1-20"
        case 21...40: return "21-40"
        default: return "41+"
        }
    }

    private func setProperty(_ value: String?, _ name: String) {
        Analytics.setUserProperty(value, forName: name)
    }
}
