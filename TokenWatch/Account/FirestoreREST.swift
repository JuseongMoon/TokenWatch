//
//  FirestoreREST.swift
//  TokenWatch
//
//  앱 계정 프로필용 Firestore REST 부품(순수 함수, 단위 테스트 대상):
//  값 인코딩·디코딩, `documents:commit` 쓰기 묶음, `Date` 헤더 기반 서버 시차.
//  Firestore SDK를 붙이지 않는다 — 공지 피드와 같은 "HTTPS + JSON" 접점이다.
//

import Foundation

/// Firestore 문서 필드 값 중 프로필이 쓰는 세 가지. 정수는 JSON에서 10진 문자열(`integerValue`)이다.
nonisolated enum FirestoreValue: Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case map([String: FirestoreValue])

    var json: [String: Any] {
        switch self {
        case .string(let s): return ["stringValue": s]
        case .integer(let n): return ["integerValue": String(n)]
        case .map(let fields): return ["mapValue": ["fields": fields.mapValues(\.json)]]
        }
    }

    /// 모르는 값 종류는 nil(무시). `integerValue`는 문자열·숫자 둘 다 받는다.
    init?(json: Any) {
        guard let dict = json as? [String: Any] else { return nil }
        if let s = dict["stringValue"] as? String {
            self = .string(s)
        } else if let raw = dict["integerValue"] {
            if let s = raw as? String, let n = Int64(s) { self = .integer(n) }
            else if let n = raw as? NSNumber { self = .integer(n.int64Value) }
            else { return nil }
        } else if let mapValue = dict["mapValue"] as? [String: Any] {
            let fields = mapValue["fields"] as? [String: Any] ?? [:]
            self = .map(fields.compactMapValues(FirestoreValue.init(json:)))
        } else {
            return nil
        }
    }

    var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    var integerValue: Int64? { if case .integer(let n) = self { return n } else { return nil } }
    var mapValue: [String: FirestoreValue]? { if case .map(let m) = self { return m } else { return nil } }
}

/// `documents:commit`의 쓰기 한 건.
nonisolated enum FirestoreWrite: Equatable, Sendable {
    /// `exists`: nil = 전제조건 없음, false = 새 문서만, true = 기존 문서만.
    /// `mask`: nil이면 문서 전체를 바꿔치기한다 — **기존 문서에는 반드시 마스크를 준다**(서버 전용 필드 보존).
    case update(name: String, fields: [String: FirestoreValue], mask: [String]?, exists: Bool?)
    case delete(name: String)

    var json: [String: Any] {
        switch self {
        case .update(let name, let fields, let mask, let exists):
            var w: [String: Any] = ["update": ["name": name, "fields": fields.mapValues(\.json)]]
            if let mask { w["updateMask"] = ["fieldPaths": mask] }
            if let exists { w["currentDocument"] = ["exists": exists] }
            return w
        case .delete(let name):
            return ["delete": name]
        }
    }
}

/// 프로필 문서 경로·쓰기 묶음(계약 §4-2). 생성·닉네임 변경은 players와 nicknames를 한 커밋으로 묶는다.
nonisolated struct PlayerDocuments: Sendable {
    let projectID: String

    var root: String { "projects/\(projectID)/databases/(default)/documents" }
    func player(_ uid: String) -> String { "\(root)/players/\(uid)" }
    func nickname(_ lower: String) -> String { "\(root)/nicknames/\(lower)" }

    static let nicknameMask = ["nickname", "nicknameLower", "nicknameChangedAtMs", "updatedAtMs"]
    static let avatarMask = ["avatar", "updatedAtMs"]
    static let termsMask = ["termsAcceptedVersion", "updatedAtMs"]

    static func avatarValue(_ id: String) -> FirestoreValue {
        .map(["kind": .string("preset"), "id": .string(id)])
    }

    /// 프로필 생성: players(새 문서) + nicknames 예약(새 문서).
    func create(uid: String, profile p: PlayerProfile) -> [FirestoreWrite] {
        let fields: [String: FirestoreValue] = [
            "nickname": .string(p.nickname),
            "nicknameLower": .string(p.nicknameLower),
            "nicknameChangedAtMs": .integer(p.nicknameChangedAtMs),
            "avatar": Self.avatarValue(p.avatarID),
            "termsAcceptedVersion": .integer(Int64(p.termsAcceptedVersion)),
            "createdAtMs": .integer(p.createdAtMs),
            "updatedAtMs": .integer(p.updatedAtMs),
        ]
        return [
            .update(name: player(uid), fields: fields, mask: nil, exists: false),
            .update(name: nickname(p.nicknameLower), fields: ["uid": .string(uid)], mask: nil, exists: false),
        ]
    }

    /// 닉네임 변경: players(마스크) + 새 예약 + 옛 예약 삭제. 대소문자만 바뀌면 예약 키가 같아 players만 쓴다.
    func changeNickname(uid: String, oldLower: String, nickname newNickname: String,
                        lower newLower: String, nowMs: Int64) -> [FirestoreWrite] {
        var writes: [FirestoreWrite] = [
            .update(name: player(uid), fields: [
                "nickname": .string(newNickname),
                "nicknameLower": .string(newLower),
                "nicknameChangedAtMs": .integer(nowMs),
                "updatedAtMs": .integer(nowMs),
            ], mask: Self.nicknameMask, exists: true),
        ]
        if newLower != oldLower {
            writes.append(.update(name: nickname(newLower), fields: ["uid": .string(uid)], mask: nil, exists: false))
            writes.append(.delete(name: nickname(oldLower)))
        }
        return writes
    }

    func changeAvatar(uid: String, avatarID: String, nowMs: Int64) -> [FirestoreWrite] {
        [.update(name: player(uid), fields: ["avatar": Self.avatarValue(avatarID), "updatedAtMs": .integer(nowMs)],
                 mask: Self.avatarMask, exists: true)]
    }

    func acceptTerms(uid: String, version: Int, nowMs: Int64) -> [FirestoreWrite] {
        [.update(name: player(uid), fields: ["termsAcceptedVersion": .integer(Int64(version)),
                                             "updatedAtMs": .integer(nowMs)],
                 mask: Self.termsMask, exists: true)]
    }

    /// 계정 삭제: 닉네임 예약과 프로필 문서를 함께 지운다.
    func delete(uid: String, nicknameLower: String) -> [FirestoreWrite] {
        [.delete(name: nickname(nicknameLower)), .delete(name: player(uid))]
    }

    static func commitBody(_ writes: [FirestoreWrite]) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["writes": writes.map(\.json)], options: [.sortedKeys])
    }

    /// `GET players/{uid}` 응답 → 프로필. 필수 필드가 빠지면 nil.
    /// 아바타가 프리셋이 아니면(V2 이후 종류) 기본 아바타로 읽는다.
    static func decodeProfile(_ data: Data) -> PlayerProfile? {
        guard let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = doc["fields"] as? [String: Any] else { return nil }
        let f = raw.compactMapValues(FirestoreValue.init(json:))
        guard let nickname = f["nickname"]?.stringValue,
              let lower = f["nicknameLower"]?.stringValue,
              let changed = f["nicknameChangedAtMs"]?.integerValue,
              let created = f["createdAtMs"]?.integerValue else { return nil }
        let avatar = f["avatar"]?.mapValue
        let avatarID = avatar?["kind"]?.stringValue == "preset" ? avatar?["id"]?.stringValue : nil
        return PlayerProfile(
            nickname: nickname, nicknameLower: lower, nicknameChangedAtMs: changed,
            avatarID: avatarID ?? AvatarCatalog.fallbackID,
            termsAcceptedVersion: Int(f["termsAcceptedVersion"]?.integerValue ?? 0),
            createdAtMs: created, updatedAtMs: f["updatedAtMs"]?.integerValue ?? created)
    }

    /// `GET nicknames/{lower}` 응답 → 예약한 uid.
    static func decodeNicknameOwner(_ data: Data) -> String? {
        guard let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = doc["fields"] as? [String: Any] else { return nil }
        return raw["uid"].flatMap(FirestoreValue.init(json:))?.stringValue
    }
}

/// 서버 시각 보정. 규칙이 클라이언트 시각을 `request.time` ±60초로 검사하므로,
/// 직전 Firestore 응답의 `Date` 헤더(초 단위)로 구한 시차를 더해 넣는다.
nonisolated struct ServerClock: Equatable, Sendable {
    /// 서버 − 기기(밀리초). nil이면 아직 모른다 — 쓰기 전에 GET으로 먼저 구한다.
    private(set) var offsetMs: Int64?

    mutating func record(dateHeader: String?, receivedAt local: Date) {
        guard let dateHeader, let server = Self.parseHTTPDate(dateHeader) else { return }
        offsetMs = Int64(((server.timeIntervalSince1970 - local.timeIntervalSince1970) * 1000).rounded())
    }

    func nowMs(local: Date = Date()) -> Int64 {
        Int64((local.timeIntervalSince1970 * 1000).rounded()) + (offsetMs ?? 0)
    }

    /// RFC 7231 IMF-fixdate(`Sun, 06 Nov 1994 08:49:37 GMT`).
    static func parseHTTPDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)
    }
}
