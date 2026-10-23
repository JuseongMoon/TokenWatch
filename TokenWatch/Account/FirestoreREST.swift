//
//  FirestoreREST.swift
//  TokenWatch
//
//  앱 계정 프로필용 Firestore REST 부품(순수 함수, 단위 테스트 대상):
//  값 디코딩, 프로필 문서 읽기, `Date` 헤더 기반 서버 시차. 프로필 쓰기는 V2 서버 callable(`setProfile`)이 한다.
//  Firestore SDK를 붙이지 않는다 — 공지 피드와 같은 "HTTPS + JSON" 접점이다.
//

import Foundation

/// Firestore 문서 필드 값 중 프로필이 쓰는 세 가지. 정수는 JSON에서 10진 문자열(`integerValue`)이다.
nonisolated enum FirestoreValue: Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case map([String: FirestoreValue])

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

/// 프로필 문서 경로와 디코딩(계약 §4-2).
nonisolated struct PlayerDocuments: Sendable {
    let projectID: String

    var root: String { "projects/\(projectID)/databases/(default)/documents" }

    /// `GET players/{uid}` 응답 → 프로필. 필수 필드(태그 포함)가 빠지면 nil.
    /// 아바타가 프리셋이 아니면(V2 이후 종류) 기본 아바타로 읽는다.
    static func decodeProfile(_ data: Data) -> PlayerProfile? {
        guard let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = doc["fields"] as? [String: Any] else { return nil }
        let f = raw.compactMapValues(FirestoreValue.init(json:))
        guard let nickname = f["nickname"]?.stringValue,
              let lower = f["nicknameLower"]?.stringValue,
              let tag = f["tag"]?.stringValue, NicknamePolicy.isValidTag(tag),
              let changed = f["nicknameChangedAtMs"]?.integerValue,
              let created = f["createdAtMs"]?.integerValue else { return nil }
        let avatar = f["avatar"]?.mapValue
        let avatarID = avatar?["kind"]?.stringValue == "preset" ? avatar?["id"]?.stringValue : nil
        return PlayerProfile(
            nickname: nickname, nicknameLower: lower, tag: tag, nicknameChangedAtMs: changed,
            avatarID: avatarID ?? AvatarCatalog.fallbackID,
            termsAcceptedVersion: Int(f["termsAcceptedVersion"]?.integerValue ?? 0),
            createdAtMs: created, updatedAtMs: f["updatedAtMs"]?.integerValue ?? created)
    }
}

/// 서버 시각 보정. 닉네임 30일 간격을 서버 시각 기준으로 미리 보여 주려고,
/// 직전 Firestore 응답의 `Date` 헤더(초 단위)로 구한 시차를 기기 시각에 더한다.
nonisolated struct ServerClock: Equatable, Sendable {
    /// 서버 − 기기(밀리초). nil이면 아직 모른다 — 필요할 때 GET으로 먼저 구한다.
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
