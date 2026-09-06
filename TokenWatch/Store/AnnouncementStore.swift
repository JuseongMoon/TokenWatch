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
//  공지함(AnnouncementListSheet)도 이 스토어를 본다:
//   - `inbox`는 지난 공지까지 포함한 목록(팝업 규칙과 달리 endAt·버전·dismiss를 무시).
//   - `seen`은 "읽음" 표시 전용이라 팝업 로직(dismissed/closedThisLaunch)과 완전히 분리돼 있다.
//     목록에서 읽어도 팝업은 팝업의 [다시 열지 않기]로만 꺼진다.
//   - `feed`/`seen`은 관찰되는 저장 프로퍼티여야 한다(@ObservationIgnored를 붙이면
//     읽음 표시·배지가 갱신되지 않는다). 파생값(inbox·unreadCount)은 computed로 둔다.
//

import Foundation
import Observation

@MainActor
@Observable
final class AnnouncementStore {
    /// 지금 화면에 띄울 공지. nil이면 오버레이 없음.
    private(set) var presented: Announcement?
    /// 마지막으로 확보한 피드(캐시 또는 네트워크). 공지함 목록의 원본이다.
    private(set) var feed: AnnouncementFeed?
    /// 읽은 공지 ID(삽입 순서). 배지·굵기 표시에만 쓰이고 팝업 로직과 무관하다.
    private(set) var seen: [String]

    static let dismissedKey = "tokenwatch.announcements.dismissed"
    static let seenKey = "tokenwatch.announcements.seen"
    static let cachedFeedKey = "tokenwatch.announcements.cachedFeed"
    static let lastSuccessKey = "tokenwatch.announcements.lastSuccessAt"
    /// ID 목록 상한. 넘치면 오래된 것부터 버린다(공지는 드물어 실질적으로 도달하지 않음).
    static let dismissedCap = 200

    /// 성공 후 재조회 최소 간격(포그라운드 복귀 스로틀).
    @ObservationIgnored private let minRefetchInterval: TimeInterval = 60 * 60
    /// 실패 후 재시도 유예. 비행기 모드에서 active/inactive가 반복돼도 요청이 몰리지 않게.
    @ObservationIgnored private let failureBackoff: TimeInterval = 5 * 60

    @ObservationIgnored private var hasCheckedThisLaunch = false
    /// 마지막 조회 실패 시각. 공지함의 "불러오지 못함" 안내가 이 값을 보므로 관찰 대상으로 둔다.
    private var lastAttemptFailedAt: Date?
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
        self.dismissed = Self.loadIDs(key: Self.dismissedKey, from: defaults)
        self.seen = Self.loadIDs(key: Self.seenKey, from: defaults)
        // 캐시는 여기서 한 번만 디코드한다 — 이후 판정·목록은 전부 이 feed를 본다.
        self.feed = Self.loadCachedFeed(from: defaults)
    }

    // MARK: - 조회

    /// scenePhase가 .active가 될 때마다 호출된다. 실제 네트워크 요청 여부는 여기서 판단한다.
    func check() {
        // 1) 캐시로 즉시 판정 — 네트워크를 기다리지 않고, 오프라인이어도 뜬다.
        if presented == nil {
            presented = pick(from: feed)
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
        case .feed(let fetched):
            feed = fetched
            storeCache(fetched)
            defaults.set(now().timeIntervalSince1970, forKey: Self.lastSuccessKey)
            lastAttemptFailedAt = nil
            // 이미 카드를 읽고 있으면 바꿔치기하지 않는다. 다음 check()에서 새 피드로 판정된다.
            if presented == nil { presented = pick(from: fetched) }
        case .empty:
            feed = nil
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

    // MARK: - 공지함(목록)

    /// 공지함에 보여줄 목록(최신순). 지난 공지도 포함한다 — 규칙은 `AnnouncementSelector.inbox` 참고.
    /// 항목 수가 많아야 수십 건이라 저장 프로퍼티로 캐시하지 않는다(피드와 이중 진실을 만들지 않고,
    /// 예약 공지의 공개 시각이 지나는 순간도 자연히 반영된다).
    var inbox: [Announcement] { AnnouncementSelector.inbox(from: feed, now: now()) }

    /// 안 읽은 공지 수(배지). **현재 노출 중인 공지만** 센다 — 업데이트 직후 첫 실행에
    /// 지난 공지 전체가 "안 읽음"으로 잡혀 배지가 켜지는 걸 막는다.
    var unreadCount: Int { inbox.filter { isUnread($0) }.count }

    /// 목록 행을 굵게 + 점으로 표시할지. `unreadCount`와 같은 규칙이다.
    func isUnread(_ a: Announcement) -> Bool {
        guard !seen.contains(a.id) else { return false }
        return AnnouncementSelector.isEligible(a, nowMs: Int64(now().timeIntervalSince1970 * 1000),
                                               appVersion: appVersion)
    }

    /// 한 번도 피드를 확보하지 못한 채 조회에 실패한 상태(공지함의 "불러오지 못함" 안내용).
    /// 캐시가 있으면 오프라인이어도 목록을 보여줄 수 있으므로 실패로 치지 않는다.
    var lastFetchFailed: Bool { feed == nil && lastAttemptFailedAt != nil }

    /// 읽음 표시. 팝업 로직(dismissed·closedThisLaunch·presented)은 건드리지 않는다 —
    /// 목록에서 읽는 것과 팝업을 끄는 것은 별개라는 제품 결정에 따른다.
    func markSeen(_ id: String) {
        guard !seen.contains(id) else { return }
        seen = Self.appendCapped(id, to: seen)
        saveIDs(seen, key: Self.seenKey)
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
            dismissed = Self.appendCapped(a.id, to: dismissed)
            saveIDs(dismissed, key: Self.dismissedKey)
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

    private static func loadCachedFeed(from defaults: UserDefaults) -> AnnouncementFeed? {
        guard let data = defaults.data(forKey: cachedFeedKey) else { return nil }
        return AnnouncementFeedClient.decodePayload(data)
    }

    private func storeCache(_ feed: AnnouncementFeed?) {
        if let feed, let data = try? JSONEncoder().encode(feed) {
            defaults.set(data, forKey: Self.cachedFeedKey)
        } else {
            defaults.removeObject(forKey: Self.cachedFeedKey)
        }
    }

    /// dismissed·seen이 공유하는 ID 목록 입출력(삽입 순서 유지 + 상한).
    private static func loadIDs(key: String, from defaults: UserDefaults) -> [String] {
        guard let data = defaults.data(forKey: key),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
    }

    private func saveIDs(_ ids: [String], key: String) {
        if let data = try? JSONEncoder().encode(ids) {
            defaults.set(data, forKey: key)
        }
    }

    private static func appendCapped(_ id: String, to list: [String]) -> [String] {
        var next = list
        next.append(id)
        if next.count > dismissedCap { next.removeFirst(next.count - dismissedCap) }
        return next
    }
}
