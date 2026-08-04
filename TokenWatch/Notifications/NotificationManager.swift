//
//  NotificationManager.swift
//  TokenWatch
//
//  로컬 알림 발화·예약의 side-effect를 담당하는 얇은 어댑터. 순수 정책(ResetDetector,
//  ResetSchedulePolicy)이 "무엇을" 결정하고, 이 매니저가 UNUserNotificationCenter로
//  "어떻게" 실행한다. 문구는 호출측(AgentStore)이 L10n으로 이미 현지화해 넘기므로
//  매니저는 현지화를 모른다. 앱 시작 시 delegate로 등록해 포그라운드에서도 배너를 띄운다.
//

import Foundation
import UserNotifications

/// 알림 설정 UserDefaults 키 — SettingsSheet(@AppStorage)와 AgentStore가 공유한다.
/// 기본값: 주간 ON(키 부재 시 true로 해석), 세션 OFF(키 부재 시 false).
enum NotificationDefaults {
    static let sessionKey = "tokenwatch.notifySession"
    static let weeklyKey = "tokenwatch.notifyWeekly"
}

/// 감지형(서프라이즈) 즉시 알림 하나 — 콘텐츠는 이미 현지화됨.
struct FiredNotification: Sendable {
    let identifier: String
    let title: String
    let body: String
    let agentID: String?
}

/// 예약형(정시) 알림 하나 — 콘텐츠는 이미 현지화됨.
struct ScheduledNotification: Sendable {
    let identifier: String
    let fireTime: Date
    let title: String
    let body: String
    let agentID: String?
}

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()

    /// 앱 시작 시 1회: 포그라운드에서도 알림을 표시하도록 delegate를 등록한다.
    func configure() {
        center.delegate = self
    }

    // MARK: 권한

    /// 아직 결정되지 않았으면 조용한(provisional) 권한을 요청한다.
    /// provisional은 프롬프트 없이 알림센터로 배달되고, 사용자가 첫 알림에서 유지/승격을 고른다.
    func requestAuthorizationIfNeeded() async {
        let status = await center.notificationSettings().authorizationStatus
        guard status == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .provisional])
    }

    /// 알림이 배달 가능한 상태인지(authorized 또는 provisional).
    func isAuthorized() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    /// 사용자가 알림을 명시적으로 거부한 상태인지(설정 안내를 띄울지 판정). notDetermined는 제외.
    func isDenied() async -> Bool {
        await center.notificationSettings().authorizationStatus == .denied
    }

    // MARK: 감지형 즉시 발화

    /// 서프라이즈 리셋 이벤트들을 즉시 알림으로 발화한다(권한 있을 때만).
    /// identifier가 결정론적이라, 같은 리셋을 재발화해도 iOS가 대체해 중복이 쌓이지 않는다.
    func fire(_ notifications: [FiredNotification]) async {
        guard !notifications.isEmpty, await isAuthorized() else { return }
        for n in notifications {
            let content = UNMutableNotificationContent()
            content.title = n.title
            content.body = n.body
            content.sound = .default
            if let id = n.agentID { content.userInfo = ["agentID": id] }
            // trigger nil = 즉시 발화.
            let request = UNNotificationRequest(identifier: n.identifier, content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    // MARK: 예약형 diff 재조정

    /// desired 목표들을 현재 pending과 diff해 add/remove를 실행한다.
    /// - 우리 소유(`reset|`) pending 중 desired에 없는 것은 제거(서버 재조정·창 소멸 반영).
    /// - 권한이 있을 때만 새 예약을 add한다. 이미 지난 발화시각은 감지형이 처리하므로 skip.
    func applyScheduled(_ scheduled: [ScheduledNotification], now: Date = Date()) async {
        let authorized = await isAuthorized()
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let desired = Set(scheduled.map(\.identifier))
        let (addIDs, removeIDs) = ResetSchedulePolicy.reconcile(desired: desired, pending: pending)

        if !removeIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: removeIDs)
        }
        guard authorized else { return }
        for s in scheduled where addIDs.contains(s.identifier) {
            let delay = s.fireTime.timeIntervalSince(now)
            guard delay > 0 else { continue }
            let content = UNMutableNotificationContent()
            content.title = s.title
            content.body = s.body
            content.sound = .default
            if let id = s.agentID { content.userInfo = ["agentID": id] }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            let request = UNNotificationRequest(identifier: s.identifier, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }

    /// 특정 에이전트의 예약 알림을 모두 제거한다(에이전트 삭제 시 고아 예약 정리).
    func removePending(forAgentID agentID: UUID) async {
        let prefix = "\(ResetSchedulePolicy.idPrefix)\(agentID.uuidString)|"
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let toRemove = pending.filter { $0.hasPrefix(prefix) }
        if !toRemove.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: toRemove)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// 포그라운드에서도 배너·목록·사운드로 표시한다(기본은 억제됨).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// 알림 탭으로 앱에 진입했을 때 — 어떤 종류의 리셋 알림이 열렸는지 기록한다.
    /// identifier 접두어로 예약형(reset|)과 감지형(fired|)을 구분한다.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        await MainActor.run {
            let kind: AnalyticsEvent.NotificationKind
            if id.hasPrefix(ResetDetector.firedIDPrefix) {
                kind = .resetSurprise
            } else if id.hasPrefix(ResetSchedulePolicy.idPrefix) {
                kind = .resetScheduled
            } else {
                return
            }
            AnalyticsService.shared.log(.notificationOpen(kind: kind))
        }
    }
}
