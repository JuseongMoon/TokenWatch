//
//  Announcement.swift
//  TokenWatch
//
//  서버 공지/패치노트 피드 모델 + 표시 대상 선택 규칙(docs/announcements-contract.md §1과 1:1).
//  피드는 순수 JSON(Codable)이다 — 전송 수단(지금은 Firestore 문서의 payload 문자열)과 무관하게
//  이 타입만이 양 팀의 계약이므로, 나중에 CDN/Functions/자체 API로 옮겨도 여기는 바뀌지 않는다.
//
//  - 시각은 전부 epoch 밀리초 정수. ISO 문자열(소수점 초)의 JSONDecoder 파싱 함정을 피한다.
//  - 디코딩은 관대하게: 모르는 kind는 notice로, 항목 하나가 깨져도 나머지는 살린다.
//    (구버전 앱이 미래 피드를 만나도 통째로 무력화되지 않게.) 단, schemaVersion이 다르면 전체 무시.
//

import Foundation

/// `feeds/ios.payload`에 담기는 피드 전체.
nonisolated struct AnnouncementFeed: Codable, Sendable, Equatable {
    /// 앱이 이해하는 스키마 버전. 서버 값이 다르면 피드 전체를 무시한다(미래 확장 안전판).
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    let generatedAt: Int64?
    let items: [Announcement]

    init(schemaVersion: Int = AnnouncementFeed.supportedSchemaVersion, generatedAt: Int64? = nil, items: [Announcement]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.items = items
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, generatedAt, items }

    /// 항목 배열은 lossy로 읽는다 — 한 항목의 디코딩 실패가 피드 전체를 날리지 않는다.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        generatedAt = try c.decodeIfPresent(Int64.self, forKey: .generatedAt)
        var list = try c.nestedUnkeyedContainer(forKey: .items)
        var kept: [Announcement] = []
        while !list.isAtEnd {
            if let item = try? list.decode(Announcement.self) {
                kept.append(item)
            } else {
                // 깨진 항목은 건너뛴다. 커서를 전진시키기 위해 빈 구조체로 소비한다.
                _ = try? list.decode(Skip.self)
            }
        }
        items = kept
    }

    private struct Skip: Decodable {}
}

/// 공지 1건. 서버 스키마와 필드명이 같다.
nonisolated struct Announcement: Codable, Identifiable, Sendable, Equatable {
    /// 헤더 라벨(NOTICE/PATCH)과 색을 정한다. 모르는 값은 notice로 읽는다.
    enum Kind: String, Codable, Sendable {
        case notice, patch
    }

    /// ko/en 본문 쌍. 요청 언어가 비어 있으면 다른 언어로 폴백한다.
    struct LocalizedText: Codable, Sendable, Equatable {
        var ko: String?
        var en: String?

        init(ko: String? = nil, en: String? = nil) {
            self.ko = ko
            self.en = en
        }

        func resolved(for lang: Lang) -> String {
            let preferred = lang == .ko ? ko : en
            let fallback = lang == .ko ? en : ko
            if let preferred, !preferred.isEmpty { return preferred }
            if let fallback, !fallback.isEmpty { return fallback }
            return ""
        }
    }

    let id: String
    let kind: Kind
    let priority: Int
    /// epoch ms
    let publishedAt: Int64
    let startAt: Int64?
    let endAt: Int64?
    /// "ios" | "all". 미지의 값은 다른 플랫폼으로 보고 제외한다(enum으로 강제하면 디코딩이 깨진다).
    let platform: String
    let minAppVersion: String?
    let maxAppVersion: String?
    let title: LocalizedText
    let body: LocalizedText

    init(id: String, kind: Kind = .notice, priority: Int = 0, publishedAt: Int64,
         startAt: Int64? = nil, endAt: Int64? = nil, platform: String = "ios",
         minAppVersion: String? = nil, maxAppVersion: String? = nil,
         title: LocalizedText, body: LocalizedText) {
        self.id = id
        self.kind = kind
        self.priority = priority
        self.publishedAt = publishedAt
        self.startAt = startAt
        self.endAt = endAt
        self.platform = platform
        self.minAppVersion = minAppVersion
        self.maxAppVersion = maxAppVersion
        self.title = title
        self.body = body
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, priority, publishedAt, startAt, endAt, platform, minAppVersion, maxAppVersion, title, body
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = Kind(rawValue: try c.decodeIfPresent(String.self, forKey: .kind) ?? "") ?? .notice
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        publishedAt = try c.decode(Int64.self, forKey: .publishedAt)
        startAt = try c.decodeIfPresent(Int64.self, forKey: .startAt)
        endAt = try c.decodeIfPresent(Int64.self, forKey: .endAt)
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? "all"
        minAppVersion = try c.decodeIfPresent(String.self, forKey: .minAppVersion)
        maxAppVersion = try c.decodeIfPresent(String.self, forKey: .maxAppVersion)
        title = try c.decodeIfPresent(LocalizedText.self, forKey: .title) ?? LocalizedText()
        body = try c.decodeIfPresent(LocalizedText.self, forKey: .body) ?? LocalizedText()
    }

    var publishedDate: Date { Date(timeIntervalSince1970: Double(publishedAt) / 1000) }
}

/// 피드에서 "지금 이 기기에 띄울 1건"을 고르는 순수 규칙. 네트워크·저장소를 모른다(단위 테스트 대상).
enum AnnouncementSelector {
    /// - Parameters:
    ///   - dismissed: "다시 열지 않기"로 영구 제외된 ID(기기 저장).
    ///   - closedThisLaunch: 이번 실행에서 [닫기]로 닫은 ID(다음 실행에 다시 뜬다).
    nonisolated static func pick(from feed: AnnouncementFeed?,
                                 now: Date,
                                 appVersion: String,
                                 dismissed: Set<String>,
                                 closedThisLaunch: Set<String>) -> Announcement? {
        guard let feed, feed.schemaVersion == AnnouncementFeed.supportedSchemaVersion else { return nil }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        return feed.items
            .filter {
                isEligible($0, nowMs: nowMs, appVersion: appVersion)
                    && !dismissed.contains($0.id)
                    && !closedThisLaunch.contains($0.id)
            }
            .sorted { a, b in
                a.priority != b.priority ? a.priority > b.priority : a.publishedAt > b.publishedAt
            }
            .first
    }

    /// 기간·플랫폼·앱 버전 조건(사용자 상태와 무관한 부분).
    nonisolated static func isEligible(_ a: Announcement, nowMs: Int64, appVersion: String) -> Bool {
        if let start = a.startAt, nowMs < start { return false }
        if let end = a.endAt, nowMs >= end { return false }
        guard a.platform == "ios" || a.platform == "all" else { return false }
        return versionInRange(appVersion, min: a.minAppVersion, max: a.maxAppVersion)
    }

    /// `1.0.9 < 1.0.10`처럼 숫자 단위로 비교하는 포함 범위 검사. nil은 무제한.
    nonisolated static func versionInRange(_ version: String, min: String?, max: String?) -> Bool {
        if let min, version.compare(min, options: .numeric) == .orderedAscending { return false }
        if let max, version.compare(max, options: .numeric) == .orderedDescending { return false }
        return true
    }
}
