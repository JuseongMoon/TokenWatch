//
//  AnnouncementFeedClient.swift
//  TokenWatch
//
//  공지 피드(문서 1개)를 Firestore REST로 읽는다. 인증 없음(보안 규칙이 `feeds/{id}` get만 공개),
//  민감 정보가 실리지 않으므로 ServiceStatusClient처럼 공유 세션을 쓴다.
//
//  Firestore SDK를 붙이지 않는 이유: 공지에는 실시간/오프라인 캐시가 필요 없고, 리더보드 등
//  미래 서버도 결국 HTTPS+JSON 접점이라 이 "URL 하나 → Codable" 계층을 그대로 재사용한다.
//  Firestore 고유의 인코딩(`fields.payload.stringValue`)은 이 파일의 봉투 구조체 하나에만 있다 —
//  전송을 CDN/Functions/자체 API로 바꾸면 `feedURL()`과 `decode`만 갈아끼운다.
//
//  프로젝트 ID·API 키는 번들 GoogleService-Info.plist에서 읽는다(AnalyticsService의 게이트와 동일:
//  plist가 없으면 기능이 조용히 꺼진다). Firebase API 키는 공개값이며 접근 통제는 규칙이 담당한다.
//

import Foundation

enum AnnouncementFeedClient {
    enum FetchResult: Sendable, Equatable {
        case feed(AnnouncementFeed)
        /// 404 — 피드 문서가 아직 없다. 정상("공지 없음")이라 스로틀 시각을 찍어도 된다.
        case empty
        /// 네트워크/비2xx/파싱 실패 — "이번엔 못 봤다". 호출측은 캐시를 유지하고 잠시 뒤 재시도한다.
        case failed
    }

    static func fetch() async -> FetchResult {
        guard let url = feedURL() else { return .failed }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("TokenWatch/\(appVersion)", forHTTPHeaderField: "User-Agent")
        // 콘솔에서 API 키에 iOS 앱 제한이 걸려 있어도 통과하도록 번들 ID를 명시한다(Google 규정 헤더).
        if let bundleID = Bundle.main.bundleIdentifier {
            req.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }
        req.timeoutInterval = 10
        req.cachePolicy = .reloadIgnoringLocalCacheData   // HTTP 캐시 대신 스토어의 자체 캐시를 쓴다

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else {
            return .failed
        }
        if http.statusCode == 404 { return .empty }
        guard (200..<300).contains(http.statusCode), let feed = decode(data) else { return .failed }
        return .feed(feed)
    }

    // MARK: - 디코딩 (순수 함수, 단위 테스트 대상)

    /// Firestore 문서 봉투에서 `payload` 문자열을 꺼내 피드로 디코드한다. 어느 단계든 실패하면 nil.
    nonisolated static func decode(_ data: Data) -> AnnouncementFeed? {
        guard let envelope = try? JSONDecoder().decode(FirestoreDocumentEnvelope.self, from: data),
              let payload = envelope.fields?.payload?.stringValue,
              let payloadData = payload.data(using: .utf8) else { return nil }
        return decodePayload(payloadData)
    }

    /// 순수 피드 JSON(payload 그 자체)을 디코드한다. 캐시 복원과 전송 교체 시에도 이 함수를 쓴다.
    nonisolated static func decodePayload(_ data: Data) -> AnnouncementFeed? {
        try? JSONDecoder().decode(AnnouncementFeed.self, from: data)
    }

    /// Firestore REST `documents.get` 응답의 필요한 부분만.
    private nonisolated struct FirestoreDocumentEnvelope: Decodable {
        struct Fields: Decodable {
            let payload: StringField?
        }
        struct StringField: Decodable {
            let stringValue: String?
        }
        let fields: Fields?
    }

    // MARK: - 엔드포인트

    /// `GET .../documents/feeds/ios?key=API_KEY`. plist가 없거나 값이 비어 있으면 nil(기능 꺼짐).
    static func feedURL() -> URL? {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path),
              let projectID = dict["PROJECT_ID"] as? String, !projectID.isEmpty,
              let apiKey = dict["API_KEY"] as? String, !apiKey.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "firestore.googleapis.com"
        components.path = "/v1/projects/\(projectID)/databases/(default)/documents/feeds/ios"
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        return components.url
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}
