//
//  PlayerProfileClient.swift
//  TokenWatch
//
//  앱 계정 프로필(`players/{uid}`)을 Firestore REST로 읽는다. 쓰기는 V2 서버 callable(`setProfile`)이 한다.
//  인증은 Firebase ID 토큰(`Authorization: Bearer`) — 요청 직전에 받아 헤더에만 싣고, 저장·로깅하지 않는다.
//  자격증명이 실리는 요청이라 APISession(ephemeral)을 쓴다. 실패는 던지지 않고 결과 열거로 돌려준다.
//  401·403이면 토큰을 강제 갱신해 한 번만 다시 보낸다(403: 운영자 클레임이 막 붙어 옛 토큰에 없을 때).
//  응답 본문(원문 에러)은 표시·기록하지 않는다.
//

import Foundation

@MainActor
final class PlayerProfileClient {
    /// ID 토큰 공급자. forceRefresh=true면 캐시를 버리고 새로 받는다. 로그인 전이면 nil.
    typealias TokenProvider = (_ forceRefresh: Bool) async -> String?
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    enum FetchResult: Equatable {
        case found(PlayerProfile)
        /// 404 — 프로필이 아직 없다(첫 로그인 또는 삭제 후).
        case notFound
        case failed
    }

    let documents: PlayerDocuments
    private let token: TokenProvider
    private let transport: Transport
    private(set) var clock = ServerClock()

    init(projectID: String, token: @escaping TokenProvider,
         transport: @escaping Transport = { try await APISession.shared.data(for: $0) }) {
        self.documents = PlayerDocuments(projectID: projectID)
        self.token = token
        self.transport = transport
    }

    /// 번들 plist의 `PROJECT_ID`. 없으면 계정 기능을 끈다.
    static func bundledProjectID() -> String? {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path),
              let id = dict["PROJECT_ID"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// 서버 시각(시차 보정). 시차를 모르면 기기 시각 그대로다.
    var nowMs: Int64 { clock.nowMs() }
    var knowsServerTime: Bool { clock.offsetMs != nil }

    // MARK: 읽기

    func fetchProfile(uid: String) async -> FetchResult {
        guard let (data, status) = await get("players/\(uid)") else { return .failed }
        switch status {
        case 200: return PlayerDocuments.decodeProfile(data).map(FetchResult.found) ?? .failed
        case 404: return .notFound
        default: return .failed
        }
    }

    // MARK: 서버 시각

    /// 닉네임 30일 간격을 서버 시각으로 미리 따지려고 시차를 확보한다(로그인 직후 프로필 GET이 보통 먼저 채운다).
    func ensureServerTime(uid: String) async {
        guard !knowsServerTime else { return }
        _ = await get("players/\(uid)")
    }

    // MARK: 전송

    /// `documents/{path}` GET. 전송 실패면 nil. 401·403이면 토큰을 강제 갱신해 한 번 다시 보낸다.
    private func get(_ path: String) async -> (Data, Int)? {
        guard let encoded = "/v1/\(documents.root)/\(path)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://firestore.googleapis.com" + encoded) else { return nil }
        for attempt in 0..<2 {
            guard let idToken = await token(attempt > 0) else { return nil }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 15
            req.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, response) = try? await transport(req),
                  let http = response as? HTTPURLResponse else { return nil }
            clock.record(dateHeader: http.value(forHTTPHeaderField: "Date"), receivedAt: Date())
            if http.statusCode == 401 || http.statusCode == 403, attempt == 0 { continue }
            return (data, http.statusCode)
        }
        return nil
    }
}
