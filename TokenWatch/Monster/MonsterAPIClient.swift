//
//  MonsterAPIClient.swift
//  TokenWatch
//
//  V2 서버(Cloud Functions callable, 계약 §15) 호출. SDK 없이 REST로 부른다:
//  `POST https://asia-northeast3-{project}.cloudfunctions.net/{name}`, 본문 `{"data": …}`, 응답 `{"result": …}`.
//  오류는 `error.details.code` 열거 문자열만 쓴다 — `message`는 표시·로깅하지 않는다.
//  ID 토큰은 요청 직전에 받아 헤더에만 싣는다. 401이면 토큰을 강제 갱신해 한 번 다시 보낸다.
//  리더보드 상위 100(이번 주·전체)은 Firestore REST runQuery로 직접 읽는다(공개 읽기 규칙, §15-6·§15-10).
//  앱 계정의 프로필 쓰기(`setProfile`)·계정 삭제(`deleteAccount`)도 이 클라이언트로 부른다(AccountStore).
//
//  보내는 것: provider·창 label·주기·리셋 버킷·슬롯·플랫폼·앱 버전. 사용률 수치, AI 서비스 계정 정보,
//  기기 식별자는 보내지 않는다.
//

import Foundation

/// 서버가 돌려준 encounter(§15-4).
nonisolated struct MonsterEncounterDTO: Equatable, Sendable {
    let key: String
    let source: String
    let provider: String
    let windowLabel: String
    let resetBucketMs: Int64?
    let slotStartMs: Int64?
    let monsterID: String
    let maxHP: Int
    let state: String
    let spawnedAtMs: Int64
    let expiresAtMs: Int64
    let defeatedAtMs: Int64?
    let awardedScore: Int?

    init?(json: [String: Any]) {
        guard let key = json["key"] as? String, let source = json["source"] as? String,
              let provider = json["provider"] as? String, let label = json["windowLabel"] as? String,
              let monsterID = json["monsterId"] as? String, let maxHP = Self.int(json["maxHP"]),
              let state = json["state"] as? String, let spawned = Self.int64(json["spawnedAtMs"]),
              let expires = Self.int64(json["expiresAtMs"]) else { return nil }
        self.key = key
        self.source = source
        self.provider = provider
        self.windowLabel = label
        self.resetBucketMs = Self.int64(json["resetBucketMs"])
        self.slotStartMs = Self.int64(json["slotStartMs"])
        self.monsterID = monsterID
        self.maxHP = max(1, maxHP)
        self.state = state
        self.spawnedAtMs = spawned
        self.expiresAtMs = expires
        self.defeatedAtMs = Self.int64(json["defeatedAtMs"])
        self.awardedScore = Self.int(json["awardedScore"])
    }

    static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue ?? (v as? String).flatMap { Int($0) } }
    static func int64(_ v: Any?) -> Int64? { (v as? NSNumber)?.int64Value ?? (v as? String).flatMap { Int64($0) } }
}

nonisolated struct MonsterStatsDTO: Equatable, Sendable {
    var totalScore = 0
    var commonKills = 0
    var specialKills = 0

    init(totalScore: Int = 0, commonKills: Int = 0, specialKills: Int = 0) {
        self.totalScore = totalScore
        self.commonKills = commonKills
        self.specialKills = specialKills
    }

    init(json: [String: Any]?) {
        totalScore = MonsterEncounterDTO.int(json?["totalScore"]) ?? 0
        commonKills = MonsterEncounterDTO.int(json?["commonKills"]) ?? 0
        specialKills = MonsterEncounterDTO.int(json?["specialKills"]) ?? 0
    }
}

/// 순위표 탭. 이번 주는 한국 시간 월요일 0시에 새로 시작한다(§15-10).
nonisolated enum LeaderboardScope: String, CaseIterable, Sendable {
    case week
    case allTime
}

/// 리더보드 한 줄(공개 문서 `leaderboard/{uid}`). 점수·처치 수는 탭에 맞는 값(이번 주 또는 전체)이다.
nonisolated struct LeaderboardEntry: Equatable, Sendable, Identifiable {
    let uid: String
    let nickname: String
    let tag: String
    let avatarID: String
    let score: Int
    let reachedAtMs: Int64
    let commonKills: Int
    let specialKills: Int
    var id: String { uid }
}

nonisolated struct MyRankDTO: Equatable, Sendable {
    /// 이번 주 순위. 서버가 아직 주간 값을 주지 않으면 순위 없음(0점)이다.
    struct Week: Equatable, Sendable {
        var weekID: String?
        var listed = false
        var rank: Int?
        var score = 0
        var commonKills = 0
        var specialKills = 0
    }

    let listed: Bool
    let rank: Int?
    let stats: MonsterStatsDTO
    var week = Week()
}

@MainActor
final class MonsterAPIClient {
    typealias TokenProvider = PlayerProfileClient.TokenProvider
    typealias Transport = PlayerProfileClient.Transport

    /// 실패 사유. `server(code)`는 계약의 `details.code`(예: `consent_required`, `daily_cap`).
    enum CallError: Error, Equatable {
        case notSignedIn
        case transport
        case server(String)
    }

    static let region = "asia-northeast3"
    static let platform = "ios"
    static let spriteFormat = 1

    private let projectID: String
    private let apiKey: String?
    private let token: TokenProvider
    private let transport: Transport
    let appVersion: String

    init(projectID: String, apiKey: String?, token: @escaping TokenProvider,
         transport: @escaping Transport = { try await APISession.shared.data(for: $0) },
         appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") {
        self.projectID = projectID
        self.apiKey = apiKey
        self.token = token
        self.transport = transport
        self.appVersion = appVersion
    }

    /// 번들 plist의 API 키(공개값 — 접근 통제는 규칙·키 제한이 한다).
    static func bundledAPIKey() -> String? {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path),
              let key = dict["API_KEY"] as? String, !key.isEmpty else { return nil }
        return key
    }

    // MARK: 출현·처치

    enum SpawnResult: Equatable {
        case encounter(MonsterEncounterDTO)
        /// 확률에서 안 나왔거나 동시 생존 상한.
        case none
    }

    func spawnCompletion(provider: String, windowLabel: String, periodSec: Int64, resetBucketMs: Int64,
                         resetsAtMs: Int64) async -> Result<SpawnResult, CallError> {
        await spawn(["source": "completion", "provider": provider, "windowLabel": windowLabel,
                     "periodSec": periodSec, "resetBucketMs": resetBucketMs, "resetsAtMs": resetsAtMs])
    }

    func spawnRandom(slotStartMs: Int64, candidates: [(provider: String, windowLabel: String)]) async
        -> Result<SpawnResult, CallError> {
        await spawn(["source": "random", "slotStartMs": slotStartMs,
                     "candidates": candidates.map { ["provider": $0.provider, "windowLabel": $0.windowLabel] }])
    }

    private func spawn(_ data: [String: Any]) async -> Result<SpawnResult, CallError> {
        var body = data
        body["platform"] = Self.platform
        body["appVersion"] = appVersion
        body["spriteFormat"] = Self.spriteFormat
        return await call("spawnEncounter", body).map { result in
            guard let json = result["encounter"] as? [String: Any], let dto = MonsterEncounterDTO(json: json) else {
                return .none
            }
            return .encounter(dto)
        }
    }

    /// 처치 확정. 시간 범위를 벗어나 만료로 처리되면 서버는 `stats`를 돌려주지 않는다(nil — 지금 통계를 유지한다).
    func defeat(key: String, defeatedAtMs: Int64) async -> Result<(MonsterEncounterDTO?, MonsterStatsDTO?), CallError> {
        await call("defeatEncounter", ["key": key, "defeatedAtMs": defeatedAtMs,
                                       "platform": Self.platform, "appVersion": appVersion]).map { result in
            ((result["encounter"] as? [String: Any]).flatMap(MonsterEncounterDTO.init(json:)),
             (result["stats"] as? [String: Any]).map { MonsterStatsDTO(json: $0) })
        }
    }

    // MARK: 계정·길드

    func acceptTerms(version: Int) async -> Result<Int, CallError> {
        await call("acceptTerms", ["version": version]).map {
            MonsterEncounterDTO.int($0["termsAcceptedVersion"]) ?? version
        }
    }

    /// 프로필 쓰기(§15-3). 닉네임 규칙·금칙어·배틀태그 추첨·30일 간격은 서버가 판정한다.
    enum ProfileChange: Equatable {
        case create(nickname: String, avatarID: String, termsVersion: Int)
        case nickname(String)
        case avatar(String)
    }

    func setProfile(_ change: ProfileChange) async -> Result<PlayerProfile, CallError> {
        let data: [String: Any]
        switch change {
        case .create(let nickname, let avatarID, let termsVersion):
            data = ["op": "create", "nickname": nickname, "avatarId": avatarID, "termsAcceptedVersion": termsVersion]
        case .nickname(let nickname):
            data = ["op": "nickname", "nickname": nickname]
        case .avatar(let avatarID):
            data = ["op": "avatar", "avatarId": avatarID]
        }
        return await call("setProfile", data).flatMap { result in
            guard let json = result["profile"] as? [String: Any], let profile = Self.decodeProfile(json) else {
                return .failure(.transport)
            }
            return .success(profile)
        }
    }

    /// 계정 삭제(§15-7). 서버가 프로필·몬스터 기록·순위·신고와 Auth 사용자까지 지운다.
    /// 5분 안에 다시 로그인한 토큰이어야 한다(아니면 `requires_recent_login`).
    func deleteAccount() async -> Result<Void, CallError> {
        await call("deleteAccount", [:]).map { _ in () }
    }

    /// `setProfile` 응답의 `profile`(일반 JSON) → 프로필. 프리셋이 아닌 아바타는 기본 아바타로 읽는다.
    nonisolated static func decodeProfile(_ json: [String: Any]) -> PlayerProfile? {
        guard let nickname = json["nickname"] as? String, let lower = json["nicknameLower"] as? String,
              let tag = json["tag"] as? String, NicknamePolicy.isValidTag(tag),
              let changed = MonsterEncounterDTO.int64(json["nicknameChangedAtMs"]),
              let created = MonsterEncounterDTO.int64(json["createdAtMs"]) else { return nil }
        let avatar = json["avatar"] as? [String: Any]
        let avatarID = avatar?["kind"] as? String == "preset" ? avatar?["id"] as? String : nil
        return PlayerProfile(
            nickname: nickname, nicknameLower: lower, tag: tag, nicknameChangedAtMs: changed,
            avatarID: avatarID ?? AvatarCatalog.fallbackID,
            termsAcceptedVersion: MonsterEncounterDTO.int(json["termsAcceptedVersion"]) ?? 0,
            createdAtMs: created, updatedAtMs: MonsterEncounterDTO.int64(json["updatedAtMs"]) ?? created)
    }

    func myRank() async -> Result<MyRankDTO, CallError> {
        await call("myRank", [:]).map(Self.decodeMyRank)
    }

    /// `myRank` 결과 → 전체·이번 주 순위. 순수 함수.
    nonisolated static func decodeMyRank(_ r: [String: Any]) -> MyRankDTO {
        var week = MyRankDTO.Week()
        if let w = r["week"] as? [String: Any] {
            week = MyRankDTO.Week(weekID: w["weekId"] as? String, listed: (w["listed"] as? Bool) ?? false,
                                  rank: MonsterEncounterDTO.int(w["rank"]), score: MonsterEncounterDTO.int(w["score"]) ?? 0,
                                  commonKills: MonsterEncounterDTO.int(w["commonKills"]) ?? 0,
                                  specialKills: MonsterEncounterDTO.int(w["specialKills"]) ?? 0)
        }
        return MyRankDTO(listed: (r["listed"] as? Bool) ?? false, rank: MonsterEncounterDTO.int(r["rank"]),
                         stats: MonsterStatsDTO(json: r), week: week)
    }

    /// 서버가 받는 게스트 이력 상한(종별 합계, §15-7). 넘으면 많이 잡은 종부터 상한까지만 보낸다.
    nonisolated static let guestHistoryCap = 500

    nonisolated static func cappedKills(_ kills: [String: Int], cap: Int = guestHistoryCap) -> [String: Int] {
        var remaining = cap
        var out: [String: Int] = [:]
        for (id, count) in kills.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key })
        where remaining > 0 && count > 0 {
            let take = min(count, remaining)
            out[id] = take
            remaining -= take
        }
        return out
    }

    func mergeGuestHistory(_ progress: MonsterGuestProgress) async -> Result<Bool, CallError> {
        var data: [String: Any] = ["kills": Self.cappedKills(progress.kills)]
        if let first = progress.firstAtMs { data["firstAtMs"] = first }
        if let last = progress.lastAtMs { data["lastAtMs"] = last }
        return await call("mergeGuestHistory", data).map { ($0["merged"] as? Bool) ?? false }
    }

    /// 신고 사유(§15-7).
    enum ReportReason: String, CaseIterable, Sendable {
        case nickname, avatar, cheating, other
    }

    func report(targetUID: String, reason: ReportReason) async -> Result<Void, CallError> {
        await call("reportPlayer", ["targetUid": targetUID, "reason": reason.rawValue]).map { _ in () }
    }

    // MARK: 리더보드

    /// 상위 100(점수 내림차순, 동점이면 먼저 도달한 순). 로그인 전에도 읽을 수 있다.
    /// 이번 주 탭은 `weekID`(그 주 월요일 KST 날짜)가 같은 문서만 주간 점수로 줄 세운다.
    func leaderboardTop(_ scope: LeaderboardScope, weekID: String, limit: Int = 100) async -> [LeaderboardEntry]? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "firestore.googleapis.com"
        components.path = "/v1/projects/\(projectID)/databases/(default)/documents:runQuery"
        if let apiKey { components.queryItems = [URLQueryItem(name: "key", value: apiKey)] }
        guard let url = components.url else { return nil }
        guard let body = try? JSONSerialization.data(withJSONObject: Self.leaderboardQuery(scope, weekID: weekID, limit: limit))
        else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bundleID = Bundle.main.bundleIdentifier {
            req.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }
        if let idToken = await token(false) { req.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await transport(req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return Self.decodeLeaderboard(data, scope: scope)
    }

    /// 탭별 필드 이름(점수·도달 시각·처치 수).
    private nonisolated static func fieldNames(_ scope: LeaderboardScope)
        -> (score: String, reachedAt: String, common: String, special: String) {
        switch scope {
        case .week: return ("weekScore", "weekReachedAtMs", "weekCommonKills", "weekSpecialKills")
        case .allTime: return ("totalScore", "scoreReachedAtMs", "commonKills", "specialKills")
        }
    }

    /// runQuery 본문. 순수 함수.
    nonisolated static func leaderboardQuery(_ scope: LeaderboardScope, weekID: String, limit: Int) -> [String: Any] {
        let f = fieldNames(scope)
        var structured: [String: Any] = [
            "from": [["collectionId": "leaderboard"]],
            "orderBy": [["field": ["fieldPath": f.score], "direction": "DESCENDING"],
                        ["field": ["fieldPath": f.reachedAt], "direction": "ASCENDING"]],
            "limit": min(100, max(1, limit)),
        ]
        if scope == .week {
            structured["where"] = ["fieldFilter": ["field": ["fieldPath": "weekId"], "op": "EQUAL",
                                                   "value": ["stringValue": weekID]]]
        }
        return ["structuredQuery": structured]
    }

    /// runQuery 응답(배열의 각 원소에 `document`) → 리더보드 줄. 필드가 빠진 문서는 버린다.
    nonisolated static func decodeLeaderboard(_ data: Data, scope: LeaderboardScope) -> [LeaderboardEntry]? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let f = fieldNames(scope)
        return rows.compactMap { row in
            guard let doc = row["document"] as? [String: Any], let name = doc["name"] as? String,
                  let raw = doc["fields"] as? [String: Any] else { return nil }
            let fields = raw.compactMapValues(FirestoreValue.init(json:))
            guard let nickname = fields["nickname"]?.stringValue, let tag = fields["tag"]?.stringValue,
                  let score = fields[f.score]?.integerValue else { return nil }
            return LeaderboardEntry(
                uid: String(name.split(separator: "/").last ?? ""), nickname: nickname, tag: tag,
                avatarID: fields["avatar"]?.stringValue ?? AvatarCatalog.fallbackID,
                score: Int(score), reachedAtMs: fields[f.reachedAt]?.integerValue ?? 0,
                commonKills: Int(fields[f.common]?.integerValue ?? 0),
                specialKills: Int(fields[f.special]?.integerValue ?? 0))
        }
    }

    // MARK: 전송

    /// callable 한 번. 401이면 토큰을 새로 받아 한 번 더.
    func call(_ name: String, _ data: [String: Any]) async -> Result<[String: Any], CallError> {
        guard let url = URL(string: "https://\(Self.region)-\(projectID).cloudfunctions.net/\(name)"),
              let body = try? JSONSerialization.data(withJSONObject: ["data": data]) else { return .failure(.transport) }
        for attempt in 0..<2 {
            guard let idToken = await token(attempt > 0) else { return .failure(.notSignedIn) }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 20
            req.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (respData, response) = try? await transport(req),
                  let http = response as? HTTPURLResponse else { return .failure(.transport) }
            if http.statusCode == 401, attempt == 0 { continue }
            return Self.decodeCallResponse(respData, status: http.statusCode)
        }
        return .failure(.transport)
    }

    /// `{"result": …}` → 성공, `{"error": {"details": {"code"}}}` → 서버 코드. 순수 함수.
    nonisolated static func decodeCallResponse(_ data: Data, status: Int) -> Result<[String: Any], CallError> {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if (200..<300).contains(status), let json {
            if let result = json["result"] as? [String: Any] { return .success(result) }
            if json["result"] is NSNull { return .success([:]) }
        }
        if let error = json?["error"] as? [String: Any] {
            if let code = (error["details"] as? [String: Any])?["code"] as? String { return .failure(.server(code)) }
            if let status = error["status"] as? String { return .failure(.server(status.lowercased())) }
        }
        return .failure(.transport)
    }
}
