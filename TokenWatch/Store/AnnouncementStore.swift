//
//  AnnouncementStore.swift
//  TokenWatch
//
//  공지 팝업의 상태 소유자. 피드를 언제 가져오고(스로틀), 무엇을 띄우며(선택 규칙),
//  사용자의 닫기/다시 열지 않기를 어디에 기억하는지(UserDefaults)를 한 곳에서 다룬다.
//  AgentStore(사용량)와는 완전히 분리 — 공지 조회가 사용량 새로고침 경로에 영향을 주지 않는다.
//
//  진입점은 `check()` 하나다(ContentView의 scenePhase .active에서 호출):
//   - 프로세스 첫 호출(=콜드 스타트)은 무조건 조회, 이후(=포그라운드 복귀)는 성공 기준 1시간 스로틀.
//   - 캐시된 피드로 즉시 판정해 띄우고, 네트워크 결과는 "표시 중이 아닐 때만" 반영한다
//     (읽고 있는 카드를 바꿔치기하지 않는다).
//   - 실패는 조용히: 시작 경로를 블로킹하지 않고(await 없음), 5분 뒤 다음 기회에 재시도.
//   - [닫기]는 이번 실행 동안만 숨김(다음 실행에 다시 뜸), [다시 열지 않기]는 영구 제외.
//

import Foundation
import Observation

@MainActor
@Observable
final class AnnouncementStore {
    /// 지금 화면에 띄울 공지. nil이면 오버레이 없음.
    private(set) var presented: Announcement?

    static let dismissedKey = "tokenwatch.announcements.dismissed"
    static let cachedFeedKey = "tokenwatch.announcements.cachedFeed"
    static let lastSuccessKey = "tokenwatch.announcements.lastSuccessAt"
    /// 영구 제외 목록 상한. 넘치면 오래된 것부터 버린다(공지는 드물어 실질적으로 도달하지 않음).
    static let dismissedCap = 200

    /// 성공 후 재조회 최소 간격(포그라운드 복귀 스로틀).
    @ObservationIgnored private let minRefetchInterval: TimeInterval = 60 * 60
    /// 실패 후 재시도 유예. 비행기 모드에서 active/inactive가 반복돼도 요청이 몰리지 않게.
    @ObservationIgnored private let failureBackoff: TimeInterval = 5 * 60

    @ObservationIgnored private var hasCheckedThisLaunch = false
    @ObservationIgnored private var lastAttemptFailedAt: Date?
    @ObservationIgnored private var inFlight = false
    /// 이번 실행에서 [닫기]로 닫은 ID — 1시간 뒤 재조회에 같은 카드가 또 뜨는 스팸을 막는다.
    @ObservationIgnored private var closedThisLaunch: Set<String> = []
    /// 영구 제외 ID(삽입 순서 유지 → 상한 초과 시 앞에서부터 제거).
    @ObservationIgnored private var dismissed: [String]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let appVersion: String
    /// 피드 조회 함수. 기본은 실제 REST 클라이언트, 테스트는 스텁을 주입해 네트워크를 타지 않는다.
    @ObservationIgnored private let fetch: @Sendable () async -> AnnouncementFeedClient.FetchResult

    init(defaults: UserDefaults = .standard,
         now: @escaping () -> Date = { Date() },
         appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
         fetch: @escaping @Sendable () async -> AnnouncementFeedClient.FetchResult = { await AnnouncementFeedClient.fetch() }) {
        self.defaults = defaults
        self.now = now
        self.appVersion = appVersion
        self.fetch = fetch
        self.dismissed = Self.loadDismissed(from: defaults)
    }

    // MARK: - 조회

    /// scenePhase가 .active가 될 때마다 호출된다. 실제 네트워크 요청 여부는 여기서 판단한다.
    func check() {
        // 1) 캐시로 즉시 판정 — 네트워크를 기다리지 않고, 오프라인이어도 뜬다.
        if presented == nil {
            presented = pick(from: cachedFeed())
        }

        // 2) 조회할 차례인가.
        let current = now()
        if hasCheckedThisLaunch {
            if let last = lastSuccessAt, current.timeIntervalSince(last) < minRefetchInterval { return }
            if let failed = lastAttemptFailedAt, current.timeIntervalSince(failed) < failureBackoff { return }
        }
        guard !inFlight else { return }
        hasCheckedThisLaunch = true
        inFlight = true

        Task { [weak self, fetch] in
            let result = await fetch()
            self?.apply(result)
        }
    }

    private func apply(_ result: AnnouncementFeedClient.FetchResult) {
        inFlight = false
        switch result {
        case .feed(let feed):
            storeCache(feed)
            defaults.set(now().timeIntervalSince1970, forKey: Self.lastSuccessKey)
            lastAttemptFailedAt = nil
            // 이미 카드를 읽고 있으면 바꿔치기하지 않는다. 다음 check()에서 새 피드로 판정된다.
            if presented == nil { presented = pick(from: feed) }
        case .empty:
            storeCache(nil)
            defaults.set(now().timeIntervalSince1970, forKey: Self.lastSuccessKey)
            lastAttemptFailedAt = nil
        case .failed:
            lastAttemptFailedAt = now()
        }
    }

    private func pick(from feed: AnnouncementFeed?) -> Announcement? {
        AnnouncementSelector.pick(from: feed, now: now(), appVersion: appVersion,
                                  dismissed: Set(dismissed), closedThisLaunch: closedThisLaunch)
    }

    // MARK: - 사용자 액션

    /// [닫기] — 이번 실행 동안만 숨긴다.
    func close() {
        guard let a = presented else { return }
        closedThisLaunch.insert(a.id)
        presented = nil
        AnalyticsService.shared.log(.announcementAction(id: a.id, action: .close))
    }

    /// [다시 열지 않기] — 이 기기에서 영구 제외한다.
    func dismissForever() {
        guard let a = presented else { return }
        closedThisLaunch.insert(a.id)
        if !dismissed.contains(a.id) {
            dismissed.append(a.id)
            if dismissed.count > Self.dismissedCap {
                dismissed.removeFirst(dismissed.count - Self.dismissedCap)
            }
            saveDismissed()
        }
        presented = nil
        AnalyticsService.shared.log(.announcementAction(id: a.id, action: .never))
    }

    /// 테스트·디버그용: 현재 영구 제외 목록(삽입 순서).
    var dismissedIDs: [String] { dismissed }

    // MARK: - 영속화

    private var lastSuccessAt: Date? {
        let t = defaults.double(forKey: Self.lastSuccessKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    private func cachedFeed() -> AnnouncementFeed? {
        guard let data = defaults.data(forKey: Self.cachedFeedKey) else { return nil }
        return AnnouncementFeedClient.decodePayload(data)
    }

    private func storeCache(_ feed: AnnouncementFeed?) {
        if let feed, let data = try? JSONEncoder().encode(feed) {
            defaults.set(data, forKey: Self.cachedFeedKey)
        } else {
            defaults.removeObject(forKey: Self.cachedFeedKey)
        }
    }

    private static func loadDismissed(from defaults: UserDefaults) -> [String] {
        guard let data = defaults.data(forKey: dismissedKey),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
    }

    private func saveDismissed() {
        if let data = try? JSONEncoder().encode(dismissed) {
            defaults.set(data, forKey: Self.dismissedKey)
        }
    }
}
