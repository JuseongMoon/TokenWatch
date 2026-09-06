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
        let store = AnnouncementStore(defaults: defaults, now: { self.now }, appVersion: "1.0.1", fetch: { .failed })
        // 캐시에 피드를 심어 check()가 네트워크 없이 즉시 판정하게 한다.
        let many = (0..<(AnnouncementStore.dismissedCap + 5)).map { item("id\($0)", priority: -$0) }
        defaults.set(try! JSONEncoder().encode(AnnouncementFeed(items: many)), forKey: AnnouncementStore.cachedFeedKey)

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
}
