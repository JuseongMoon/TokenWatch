//
//  AnnouncementTests.swift
//  TokenWatchTests
//
//  공지 피드 계약(docs/announcements-contract.md) 검증: 선택 규칙, 관대한 디코딩, Firestore 봉투,
//  언어 폴백, 스토어의 닫기/영구 제외 영속화.
//

import Testing
import Foundation
@testable import TokenWatch

struct AnnouncementTests {

    private let now = Date(timeIntervalSince1970: 1_788_652_800)   // 2026-09-06T00:00:00Z
    private var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1000) }

    private func item(_ id: String, kind: Announcement.Kind = .notice, priority: Int = 0,
                      publishedAt: Int64? = nil, startAt: Int64? = nil, endAt: Int64? = nil,
                      platform: String = "ios", min: String? = nil, max: String? = nil) -> Announcement {
        Announcement(id: id, kind: kind, priority: priority, publishedAt: publishedAt ?? nowMs,
                     startAt: startAt, endAt: endAt, platform: platform,
                     minAppVersion: min, maxAppVersion: max,
                     title: .init(ko: "제목", en: "Title"), body: .init(ko: "본문", en: "Body"))
    }

    private func pick(_ items: [Announcement], schema: Int = 1, version: String = "1.0.1",
                      dismissed: Set<String> = [], closed: Set<String> = []) -> Announcement? {
        AnnouncementSelector.pick(from: AnnouncementFeed(schemaVersion: schema, items: items),
                                  now: now, appVersion: version, dismissed: dismissed, closedThisLaunch: closed)
    }

    // MARK: 선택 규칙

    @Test func unknownSchemaVersionIsIgnored() {
        #expect(pick([item("a")], schema: 2) == nil)
        #expect(pick([item("a")], schema: 1)?.id == "a")
    }

    @Test func timeWindow() {
        #expect(pick([item("future", startAt: nowMs + 1)]) == nil)
        #expect(pick([item("started", startAt: nowMs)])?.id == "started")
        #expect(pick([item("expired", endAt: nowMs)]) == nil)         // endAt은 배타
        #expect(pick([item("live", endAt: nowMs + 1)])?.id == "live")
    }

    @Test func platform() {
        #expect(pick([item("ios", platform: "ios")]) != nil)
        #expect(pick([item("all", platform: "all")]) != nil)
        #expect(pick([item("android", platform: "android")]) == nil)
    }

    @Test func versionRangeIsNumeric() {
        #expect(AnnouncementSelector.versionInRange("1.0.10", min: "1.0.9", max: nil))
        #expect(!AnnouncementSelector.versionInRange("1.0.9", min: "1.0.10", max: nil))
        #expect(AnnouncementSelector.versionInRange("1.0.1", min: "1.0.1", max: "1.0.1"))   // 포함 범위
        #expect(!AnnouncementSelector.versionInRange("1.1", min: nil, max: "1.0.9"))
        #expect(pick([item("old-only", max: "1.0.0")], version: "1.0.1") == nil)
        #expect(pick([item("new-only", min: "1.0.1")], version: "1.0.1")?.id == "new-only")
    }

    @Test func dismissedAndClosedAreExcluded() {
        let items = [item("a", priority: 10), item("b", priority: 5)]
        #expect(pick(items)?.id == "a")
        #expect(pick(items, dismissed: ["a"])?.id == "b")
        #expect(pick(items, closed: ["a"])?.id == "b")
        #expect(pick(items, dismissed: ["a"], closed: ["b"]) == nil)
    }

    @Test func orderingPriorityThenRecency() {
        let items = [
            item("old-high", priority: 10, publishedAt: nowMs - 2000),
            item("new-low", priority: 1, publishedAt: nowMs),
            item("new-high", priority: 10, publishedAt: nowMs - 1000),
        ]
        #expect(pick(items)?.id == "new-high")
    }

    // MARK: 디코딩

    private let samplePayload = """
    {"schemaVersion":1,"generatedAt":1757116800000,"items":[
      {"id":"p1","kind":"patch","priority":10,"publishedAt":1757116800000,"startAt":null,"endAt":null,
       "platform":"ios","minAppVersion":null,"maxAppVersion":"1.0.1",
       "title":{"ko":"업데이트","en":"Update"},"body":{"ko":"본문","en":"Body"},"futureField":{"x":1}},
      {"id":"n1","kind":"link","publishedAt":1757116700000,"platform":"all",
       "title":{"ko":"","en":"English only"},"body":{"en":"Body EN"}},
      {"kind":"notice","publishedAt":1}
    ]}
    """

    @Test func payloadDecodesLeniently() throws {
        let feed = try #require(AnnouncementFeedClient.decodePayload(Data(samplePayload.utf8)))
        #expect(feed.schemaVersion == 1)
        #expect(feed.items.count == 2)                       // id 없는 세 번째 항목만 탈락
        let p1 = try #require(feed.items.first { $0.id == "p1" })
        #expect(p1.kind == .patch)
        #expect(p1.maxAppVersion == "1.0.1")
        #expect(p1.startAt == nil)
        let n1 = try #require(feed.items.first { $0.id == "n1" })
        #expect(n1.kind == .notice)                          // 모르는 kind → notice
        #expect(n1.priority == 0)
        #expect(n1.platform == "all")
    }

    @Test func firestoreEnvelopeUnwrapsPayload() throws {
        let escaped = samplePayload
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
        let envelope = """
        {"name":"projects/tokenwatch-app/databases/(default)/documents/feeds/ios",
         "fields":{"payload":{"stringValue":"\(escaped)"},
                   "schemaVersion":{"integerValue":"1"},
                   "updatedAt":{"timestampValue":"2026-09-06T00:00:00.123456Z"}},
         "createTime":"2026-09-06T00:00:00Z","updateTime":"2026-09-06T00:00:00Z"}
        """
        let feed = try #require(AnnouncementFeedClient.decode(Data(envelope.utf8)))
        #expect(feed.items.map(\.id) == ["p1", "n1"])
        #expect(AnnouncementFeedClient.decode(Data("{\"fields\":{}}".utf8)) == nil)
        #expect(AnnouncementFeedClient.decode(Data("not json".utf8)) == nil)
    }

    @Test func cacheRoundTrip() throws {
        let feed = try #require(AnnouncementFeedClient.decodePayload(Data(samplePayload.utf8)))
        let data = try JSONEncoder().encode(feed)
        #expect(AnnouncementFeedClient.decodePayload(data) == feed)
    }

    // MARK: 언어 폴백

    @Test func localizedTextFallsBack() {
        let both = Announcement.LocalizedText(ko: "한", en: "EN")
        #expect(both.resolved(for: .ko) == "한")
        #expect(both.resolved(for: .en) == "EN")
        #expect(Announcement.LocalizedText(ko: "", en: "EN").resolved(for: .ko) == "EN")
        #expect(Announcement.LocalizedText(ko: nil, en: nil).resolved(for: .en) == "")
    }

    // MARK: 스토어 영속화

    private func freshDefaults() -> UserDefaults {
        let name = "AnnouncementTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test @MainActor func dismissForeverPersistsAndCaps() {
        let defaults = freshDefaults()
        // 캐시에 피드를 심어 check()가 네트워크 없이 즉시 판정하게 한다.
        // 스토어는 init에서 캐시를 한 번만 읽으므로 반드시 생성 "전에" 심어야 한다.
        let many = (0..<(AnnouncementStore.dismissedCap + 5)).map { item("id\($0)", priority: -$0) }
        defaults.set(try! JSONEncoder().encode(AnnouncementFeed(items: many)), forKey: AnnouncementStore.cachedFeedKey)
        let store = AnnouncementStore(defaults: defaults, now: { self.now }, appVersion: "1.0.1", fetch: { .failed })

        for _ in 0..<(AnnouncementStore.dismissedCap + 5) {
            store.check()
            #expect(store.presented != nil)
            store.dismissForever()
            #expect(store.presented == nil)
        }
        #expect(store.dismissedIDs.count == AnnouncementStore.dismissedCap)
        #expect(store.dismissedIDs.first == "id5")           // 오래된 것부터 제거
        #expect(store.dismissedIDs.last == "id\(AnnouncementStore.dismissedCap + 4)")

        // 새 스토어(재실행)도 같은 목록을 읽는다.
        let reloaded = AnnouncementStore(defaults: defaults, now: { self.now }, appVersion: "1.0.1", fetch: { .failed })
        #expect(reloaded.dismissedIDs == store.dismissedIDs)
    }

    @Test @MainActor func closeHidesOnlyForThisLaunch() {
        let defaults = freshDefaults()
        defaults.set(try! JSONEncoder().encode(AnnouncementFeed(items: [item("a")])), forKey: AnnouncementStore.cachedFeedKey)

        let store = AnnouncementStore(defaults: defaults, now: { self.now }, appVersion: "1.0.1", fetch: { .failed })
        store.check()
        #expect(store.presented?.id == "a")
        store.close()
        #expect(store.presented == nil)
        store.check()                                        // 같은 실행: 다시 안 뜸
        #expect(store.presented == nil)
        #expect(store.dismissedIDs.isEmpty)                  // 영구 제외는 아님

        let relaunched = AnnouncementStore(defaults: defaults, now: { self.now }, appVersion: "1.0.1", fetch: { .failed })
        relaunched.check()                                   // 다음 실행: 다시 뜬다
        #expect(relaunched.presented?.id == "a")
    }

    // MARK: 공지함(목록) 규칙

    private func inbox(_ items: [Announcement], schema: Int = 1) -> [String] {
        AnnouncementSelector.inbox(from: AnnouncementFeed(schemaVersion: schema, items: items), now: now)
            .map(\.id)
    }

    /// 팝업에서 빠지는 조건들(기간 만료·버전 범위)이 목록에는 그대로 남아야 한다 — 이력이기 때문.
    @Test func inboxKeepsExpiredAndOutOfVersionRange() {
        let expired = item("expired", endAt: nowMs - 1)
        let oldOnly = item("old-only", max: "1.0.0")
        let future = item("future", startAt: nowMs + 1)
        let android = item("android", platform: "android")

        #expect(inbox([expired]) == ["expired"])
        #expect(inbox([oldOnly]) == ["old-only"])
        #expect(inbox([future]).isEmpty)      // 예약 공지는 공개 시각 전까지 숨김
        #expect(inbox([android]).isEmpty)     // 다른 플랫폼은 제외

        // 팝업 규칙과의 대비: 같은 항목들이 pick에서는 빠진다.
        #expect(pick([expired]) == nil)
        #expect(pick([oldOnly], version: "1.0.1") == nil)
    }

    @Test func inboxSortsNewestFirstAndIgnoresSchemaMismatch() {
        let items = [
            item("older", publishedAt: nowMs - 2000),
            item("newest", publishedAt: nowMs),
            item("mid", publishedAt: nowMs - 1000),
        ]
        #expect(inbox(items) == ["newest", "mid", "older"])
        // 같은 시각이면 id로 안정 정렬(순서가 실행마다 흔들리지 않게).
        #expect(inbox([item("b"), item("a")]) == ["a", "b"])
        #expect(inbox(items, schema: 2).isEmpty)
    }

    /// dismiss(팝업 영구 제외)는 목록과 무관하다.
    @Test @MainActor func inboxKeepsDismissedAndSurvivesRelaunch() {
        let defaults = freshDefaults()
        defaults.set(try! JSONEncoder().encode(AnnouncementFeed(items: [item("a"), item("b")])),
                     forKey: AnnouncementStore.cachedFeedKey)

        let store = AnnouncementStore(defaults: defaults, now: { self.now }, appVersion: "1.0.1", fetch: { .failed })
        // init에서 캐시를 읽으므로 check() 없이도 목록이 채워진다.
        #expect(store.inbox.map(\.id) == ["a", "b"])
        store.check()
        store.dismissForever()
        #expect(store.dismissedIDs == [store.inbox.first?.id].compactMap { $0 })
        #expect(store.inbox.count == 2)      // 목록에는 그대로 남는다
    }

    // MARK: 읽음(seen) 표시

    @Test @MainActor func markSeenPersistsAndIsIndependentFromPopup() {
        let defaults = freshDefaults()
        defaults.set(try! JSONEncoder().encode(AnnouncementFeed(items: [item("a"), item("b")])),
                     forKey: AnnouncementStore.cachedFeedKey)

        let store = AnnouncementStore(defaults: defaults, now: { self.now }, appVersion: "1.0.1", fetch: { .failed })
        #expect(store.unreadCount == 2)

        store.markSeen("a")
        #expect(store.seen == ["a"])
        #expect(store.unreadCount == 1)
        #expect(store.isUnread(store.inbox[1]))
        // 읽음은 팝업 로직을 건드리지 않는다(제품 결정: 목록 읽기와 팝업은 독립).
        #expect(store.dismissedIDs.isEmpty)
        store.check()
        #expect(store.presented?.id != nil)

        // 재실행에도 유지된다.
        let relaunched = AnnouncementStore(defaults: defaults, now: { self.now }, appVersion: "1.0.1", fetch: { .failed })
        #expect(relaunched.seen == ["a"])
        #expect(relaunched.unreadCount == 1)
    }

    /// 지난 공지는 배지에 잡히지 않는다 — 업데이트 직후 첫 실행에 이력 전체가 "안 읽음"이 되면 안 된다.
    @Test @MainActor func unreadCountsOnlyLiveAnnouncements() {
        let defaults = freshDefaults()
        let feed = AnnouncementFeed(items: [
            item("live"),
            item("expired", endAt: nowMs - 1),
            item("old-only", max: "1.0.0"),
        ])
        defaults.set(try! JSONEncoder().encode(feed), forKey: AnnouncementStore.cachedFeedKey)

        let store = AnnouncementStore(defaults: defaults, now: { self.now }, appVersion: "1.0.1", fetch: { .failed })
        #expect(store.inbox.count == 3)
        #expect(store.unreadCount == 1)
        #expect(store.inbox.filter { store.isUnread($0) }.map(\.id) == ["live"])
    }

    @Test @MainActor func seenListIsCapped() {
        let defaults = freshDefaults()
        let store = AnnouncementStore(defaults: defaults, now: { self.now }, appVersion: "1.0.1", fetch: { .failed })
        for i in 0..<(AnnouncementStore.dismissedCap + 5) { store.markSeen("id\(i)") }
        #expect(store.seen.count == AnnouncementStore.dismissedCap)
        #expect(store.seen.first == "id5")   // 오래된 것부터 제거
        store.markSeen("id5")                // 아직 목록에 있으므로 중복 추가되지 않는다
        #expect(store.seen.last == "id\(AnnouncementStore.dismissedCap + 4)")
        store.markSeen("id0")                // 잘려나간 ID는 다시 들어온다
        #expect(store.seen.last == "id0")
    }

    // MARK: 조회 실패 표시

    @Test @MainActor func lastFetchFailedOnlyWhenNoFeedAtAll() async {
        let defaults = freshDefaults()
        let store = AnnouncementStore(defaults: defaults, now: { self.now }, appVersion: "1.0.1", fetch: { .failed })
        #expect(!store.lastFetchFailed)      // 아직 시도 전
        store.check()
        await Task.yield()
        #expect(store.lastFetchFailed)
        #expect(store.inbox.isEmpty)

        // 캐시가 있으면 조회에 실패해도 목록을 보여줄 수 있으므로 실패로 치지 않는다.
        defaults.set(try! JSONEncoder().encode(AnnouncementFeed(items: [item("a")])),
                     forKey: AnnouncementStore.cachedFeedKey)
        let cached = AnnouncementStore(defaults: defaults, now: { self.now }, appVersion: "1.0.1", fetch: { .failed })
        cached.check()
        await Task.yield()
        #expect(!cached.lastFetchFailed)
        #expect(cached.inbox.map(\.id) == ["a"])
    }
}
