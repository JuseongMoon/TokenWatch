//
//  PlayerProfileClient.swift
//  TokenWatch
//
//  앱 계정 프로필(`players/{uid}`·`nicknames/{lower}`)을 Firestore REST로 읽고 쓴다.
//  인증은 Firebase ID 토큰(`Authorization: Bearer`) — 요청 직전에 받아 헤더에만 싣고, 저장·로깅하지 않는다.
//  자격증명이 실리는 요청이라 APISession(ephemeral)을 쓴다. 실패는 던지지 않고 결과 열거로 돌려준다.
//  401이면 토큰을 강제 갱신해 한 번만 다시 보낸다. 응답 본문(원문 에러)은 표시·기록하지 않는다.
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

    enum Availability: Equatable {
        case available
        case taken
        case failed
    }

    enum CommitResult: Equatable {
        case ok
        /// 닉네임 예약이 다른 계정에 있어 커밋 전체가 거절됐다.
        case taken
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
        guard let (data, status) = await send(method: "GET", path: "players/\(uid)") else { return .failed }
        switch status {
        case 200: return PlayerDocuments.decodeProfile(data).map(FetchResult.found) ?? .failed
        case 404: return .notFound
        default: return .failed
        }
    }

    /// 닉네임 예약 확인. 404면 비어 있고, 예약자가 본인이면 사용 가능이다.
    func nicknameAvailability(lower: String, uid: String) async -> Availability {
        guard let (data, status) = await send(method: "GET", path: "nicknames/\(lower)") else { return .failed }
        switch status {
        case 404: return .available
        case 200:
            guard let owner = PlayerDocuments.decodeNicknameOwner(data) else { return .failed }
            return owner == uid ? .available : .taken
        default: return .failed
        }
    }

    // MARK: 쓰기

    /// 쓰기 묶음을 원자적으로 커밋한다. 시차를 아직 모르면 먼저 GET으로 구한다(시각 필드 ±60초 규칙).
    /// `nicknameLower`를 주면 실패 시 예약을 다시 조회해 다른 계정이 가졌는지(`taken`) 가린다 —
    /// 중복 예약 실패가 어떤 HTTP 코드로 오는지는 서버 실측 전이라 상태 코드에 기대지 않는다.
    func commit(_ writes: [FirestoreWrite], uid: String, nicknameLower: String? = nil) async -> CommitResult {
        guard let body = PlayerDocuments.commitBody(writes) else { return .failed }
        if let (_, status) = await send(method: "POST", path: ":commit", body: body), (200..<300).contains(status) {
            return .ok
        }
        if let nicknameLower, await nicknameAvailability(lower: nicknameLower, uid: uid) == .taken {
            return .taken
        }
        return .failed
    }

    /// 시각 필드를 쓰기 전에 서버 시차를 확보한다(로그인 직후 프로필 GET이 보통 먼저 채운다).
    func ensureServerTime(uid: String) async {
        guard !knowsServerTime else { return }
        _ = await send(method: "GET", path: "players/\(uid)")
    }

    // MARK: 전송

    /// path는 `documents` 뒤에 붙는다(`players/x` → `/documents/players/x`, `:commit` → `/documents:commit`).
    /// 전송 실패면 nil. 401이면 토큰을 강제 갱신해 한 번 다시 보낸다.
    private func send(method: String, path: String, body: Data? = nil) async -> (Data, Int)? {
        // 한글 닉네임 문서 ID가 경로에 들어가므로 퍼센트 인코딩한다.
        let full = "/v1/\(documents.root)" + (path.hasPrefix(":") ? path : "/\(path)")
        guard let encoded = full.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://firestore.googleapis.com" + encoded) else { return nil }
        for attempt in 0..<2 {
            guard let idToken = await token(attempt > 0) else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                req.httpBody = body
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            req.timeoutInterval = 15
            req.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, response) = try? await transport(req),
                  let http = response as? HTTPURLResponse else { return nil }
            clock.record(dateHeader: http.value(forHTTPHeaderField: "Date"), receivedAt: Date())
            if http.statusCode == 401, attempt == 0 { continue }
            return (data, http.statusCode)
        }
        return nil
    }
}
