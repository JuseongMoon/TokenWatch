//
//  PlayerProfileClientTests.swift
//  TokenWatchTests
//
//  앱 계정 Firestore REST 계층 검증(계약 §3·§4).
//  - commit 묶음: 생성은 exists=false 두 건(players + nametags/{닉네임#태그}), 닉네임 변경은 updateMask(태그 포함)
//    + exists=true + 새 예약 + 옛 예약 삭제(대소문자만 바꿔도 태그가 바뀌어 항상 교체), 아바타·약관 마스크,
//    **기존 문서 쓰기에 마스크가 빠지지 않음**, 삭제 두 건
//  - 값 인코딩: integerValue는 문자열
//  - 디코딩: 모르는 필드 무시, 프리셋이 아닌 아바타는 기본 아바타
//  - Date 헤더 시차 보정
//  - 클라이언트: Bearer 헤더·`?key=` 없음, 404/200 매핑, 401 → 토큰 강제 갱신 1회 재시도,
//    본인 예약은 사용 가능, commit 실패 → 예약 재조회 → taken, 한글·`#` 문서 ID 퍼센트 인코딩
//

import Testing
import Foundation
@testable import TokenWatch

@MainActor
struct PlayerProfileClientTests {
    private let docs = PlayerDocuments(projectID: "demo-proj")
    private let profile = PlayerProfile(nickname: "Slime왕", nicknameLower: "slime왕", tag: "0042", nicknameChangedAtMs: 100,
                                        avatarID: "mage", termsAcceptedVersion: 1, createdAtMs: 100, updatedAtMs: 100)

    // MARK: commit 묶음

    @Test func createUsesTwoNewDocumentWrites() {
        let writes = docs.create(uid: "u1", profile: profile)
        #expect(writes.count == 2)
        guard case .update(let pName, let fields, let pMask, let pExists) = writes[0],
              case .update(let nName, let nFields, let nMask, let nExists) = writes[1] else {
            Issue.record("update 두 건이어야 한다"); return
        }
        #expect(pName == "projects/demo-proj/databases/(default)/documents/players/u1")
        #expect(pMask == nil && pExists == false)
        #expect(Set(fields.keys) == ["nickname", "nicknameLower", "tag", "nicknameChangedAtMs", "avatar",
                                     "termsAcceptedVersion", "createdAtMs", "updatedAtMs"])
        #expect(fields["tag"] == .string("0042"))
        #expect(fields["avatar"] == .map(["kind": .string("preset"), "id": .string("mage")]))
        #expect(nName == "projects/demo-proj/databases/(default)/documents/nametags/slime왕#0042")
        #expect(nFields == ["uid": .string("u1")])
        #expect(nMask == nil && nExists == false)
    }

    @Test func nicknameChangeMasksAndSwapsReservation() {
        let writes = docs.changeNickname(uid: "u1", oldKey: "slime왕#0042", nickname: "Goblin", lower: "goblin",
                                         tag: "8571", nowMs: 200)
        #expect(writes.count == 3)
        guard case .update(_, let fields, let mask, let exists) = writes[0] else { Issue.record(); return }
        #expect(mask == ["nickname", "nicknameLower", "tag", "nicknameChangedAtMs", "updatedAtMs"])
        #expect(exists == true)
        #expect(Set(fields.keys) == Set(mask ?? []))
        #expect(writes[1] == .update(name: docs.nametag("goblin#8571"), fields: ["uid": .string("u1")],
                                     mask: nil, exists: false))
        #expect(writes[2] == .delete(name: docs.nametag("slime왕#0042")))
    }

    /// 대소문자만 바꿔도 태그를 새로 뽑으므로 예약을 교체한다.
    @Test func caseOnlyChangeStillSwapsTag() {
        let writes = docs.changeNickname(uid: "u1", oldKey: "slime왕#0042", nickname: "SLIME왕", lower: "slime왕",
                                         tag: "1357", nowMs: 200)
        #expect(writes.count == 3)
        #expect(writes[2] == .delete(name: docs.nametag("slime왕#0042")))
    }

    @Test func avatarAndTermsUseMasks() {
        #expect(docs.changeAvatar(uid: "u1", avatarID: "cat", nowMs: 5) == [
            .update(name: docs.player("u1"),
                    fields: ["avatar": .map(["kind": .string("preset"), "id": .string("cat")]), "updatedAtMs": .integer(5)],
                    mask: ["avatar", "updatedAtMs"], exists: true)])
        #expect(docs.acceptTerms(uid: "u1", version: 2, nowMs: 5) == [
            .update(name: docs.player("u1"),
                    fields: ["termsAcceptedVersion": .integer(2), "updatedAtMs": .integer(5)],
                    mask: ["termsAcceptedVersion", "updatedAtMs"], exists: true)])
    }

    /// 기존 players 문서를 고치는 쓰기에는 반드시 마스크가 있어야 한다(V2 서버 필드 보존).
    @Test func existingPlayerWritesAlwaysHaveMask() {
        let all = docs.changeNickname(uid: "u1", oldKey: "a#0001", nickname: "bb", lower: "bb", tag: "0002", nowMs: 1)
            + docs.changeAvatar(uid: "u1", avatarID: "cat", nowMs: 1)
            + docs.acceptTerms(uid: "u1", version: 1, nowMs: 1)
        for w in all {
            if case .update(let name, _, let mask, let exists) = w, name == docs.player("u1") {
                #expect(mask != nil)
                #expect(exists == true)
            }
        }
    }

    @Test func deleteRemovesReservationAndProfile() {
        #expect(docs.delete(uid: "u1", nametagKey: "slime왕#0042") ==
                [.delete(name: docs.nametag("slime왕#0042")), .delete(name: docs.player("u1"))])
    }

    @Test func commitBodyEncodesIntegersAsStrings() throws {
        let body = try #require(PlayerDocuments.commitBody(docs.changeAvatar(uid: "u1", avatarID: "cat", nowMs: 1234)))
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let writes = try #require(json["writes"] as? [[String: Any]])
        let update = try #require(writes.first?["update"] as? [String: Any])
        let fields = try #require(update["fields"] as? [String: Any])
        let updated = try #require(fields["updatedAtMs"] as? [String: Any])
        #expect(updated["integerValue"] as? String == "1234")
        #expect((writes.first?["currentDocument"] as? [String: Any])?["exists"] as? Bool == true)
        #expect((writes.first?["updateMask"] as? [String: Any])?["fieldPaths"] as? [String] == ["avatar", "updatedAtMs"])
    }

    // MARK: 디코딩

    @Test func decodesProfileIgnoringUnknownFields() throws {
        let data = Data("""
        {"name":"projects/p/databases/(default)/documents/players/u1","fields":{
          "nickname":{"stringValue":"모험가"},"nicknameLower":{"stringValue":"모험가"},"tag":{"stringValue":"0042"},
          "nicknameChangedAtMs":{"integerValue":"1700000000000"},
          "avatar":{"mapValue":{"fields":{"kind":{"stringValue":"preset"},"id":{"stringValue":"knight"}}}},
          "termsAcceptedVersion":{"integerValue":"1"},"createdAtMs":{"integerValue":"1690000000000"},
          "updatedAtMs":{"integerValue":"1700000000001"},
          "stats":{"mapValue":{"fields":{"totalScore":{"integerValue":"9"}}}},"flag":{"booleanValue":true}
        }}
        """.utf8)
        let p = try #require(PlayerDocuments.decodeProfile(data))
        #expect(p == PlayerProfile(nickname: "모험가", nicknameLower: "모험가", tag: "0042", nicknameChangedAtMs: 1_700_000_000_000,
                                   avatarID: "knight", termsAcceptedVersion: 1, createdAtMs: 1_690_000_000_000,
                                   updatedAtMs: 1_700_000_000_001))
    }

    @Test func nonPresetAvatarFallsBack() throws {
        let data = Data("""
        {"fields":{"nickname":{"stringValue":"ab"},"nicknameLower":{"stringValue":"ab"},"tag":{"stringValue":"9999"},
          "nicknameChangedAtMs":{"integerValue":"1"},"createdAtMs":{"integerValue":"1"},
          "avatar":{"mapValue":{"fields":{"kind":{"stringValue":"photo"},"path":{"stringValue":"x"}}}}}}
        """.utf8)
        #expect(try #require(PlayerDocuments.decodeProfile(data)).avatarID == AvatarCatalog.fallbackID)
    }

    @Test func missingRequiredFieldFails() {
        #expect(PlayerDocuments.decodeProfile(Data(#"{"fields":{"nickname":{"stringValue":"ab"}}}"#.utf8)) == nil)
        // 태그가 없거나 4자리가 아니면 실패한다.
        let noTag = #"{"fields":{"nickname":{"stringValue":"ab"},"nicknameLower":{"stringValue":"ab"},"nicknameChangedAtMs":{"integerValue":"1"},"createdAtMs":{"integerValue":"1"}}}"#
        #expect(PlayerDocuments.decodeProfile(Data(noTag.utf8)) == nil)
        let badTag = noTag.replacingOccurrences(of: #""nicknameLower""#, with: #""tag":{"stringValue":"42"},"nicknameLower""#)
        #expect(PlayerDocuments.decodeProfile(Data(badTag.utf8)) == nil)
    }

    // MARK: 서버 시차

    @Test func serverClockUsesDateHeaderOffset() throws {
        let server = try #require(ServerClock.parseHTTPDate("Sun, 06 Nov 1994 08:49:37 GMT"))
        #expect(server.timeIntervalSince1970 == 784_111_777)
        var clock = ServerClock()
        #expect(clock.offsetMs == nil)
        let local = server.addingTimeInterval(-90)   // 기기가 90초 늦다
        clock.record(dateHeader: "Sun, 06 Nov 1994 08:49:37 GMT", receivedAt: local)
        #expect(clock.offsetMs == 90_000)
        #expect(clock.nowMs(local: local) == 784_111_777_000)
        clock.record(dateHeader: "garbage", receivedAt: local)
        #expect(clock.offsetMs == 90_000)   // 못 읽으면 이전 값 유지
    }

    // MARK: 클라이언트(가짜 전송)

    private func makeClient(_ server: FakeFirestore) -> PlayerProfileClient {
        PlayerProfileClient(projectID: "demo-proj",
                            token: { force in force ? "fresh-token" : "cached-token" },
                            transport: { try await server.handle($0) })
    }

    @Test func getSendsBearerWithoutKeyAndMapsStatus() async {
        let server = FakeFirestore()
        server.responses = [.init(status: 404)]
        let client = makeClient(server)
        #expect(await client.fetchProfile(uid: "u1") == .notFound)
        let req = server.requests[0]
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer cached-token")
        #expect(req.url?.query == nil)
        #expect(req.url?.path == "/v1/projects/demo-proj/databases/(default)/documents/players/u1")
        #expect(client.knowsServerTime)
    }

    @Test func retriesOnceWithFreshTokenAfter401() async {
        let server = FakeFirestore()
        server.responses = [.init(status: 401), .init(status: 404)]
        #expect(await makeClient(server).fetchProfile(uid: "u1") == .notFound)
        #expect(server.requests.map { $0.value(forHTTPHeaderField: "Authorization") } ==
                ["Bearer cached-token", "Bearer fresh-token"])
    }

    /// 403(규칙 거절)도 새 토큰으로 한 번 다시 보낸다 — 막 붙은 운영자 클레임을 반영하려고.
    @Test func retriesOnceWithFreshTokenAfter403() async {
        let server = FakeFirestore()
        server.responses = [.init(status: 403), .init(status: 200)]
        let client = makeClient(server)
        #expect(await client.commit(client.documents.changeAvatar(uid: "u1", avatarID: "cat", nowMs: 1), uid: "u1") == .ok)
        #expect(server.requests.map { $0.value(forHTTPHeaderField: "Authorization") } ==
                ["Bearer cached-token", "Bearer fresh-token"])
    }

    @Test func secondUnauthorizedFails() async {
        let server = FakeFirestore()
        server.responses = [.init(status: 401), .init(status: 401)]
        #expect(await makeClient(server).fetchProfile(uid: "u1") == .failed)
        #expect(server.requests.count == 2)
    }

    @Test func ownReservationIsAvailable() async {
        let server = FakeFirestore()
        server.responses = [.init(status: 200, body: #"{"fields":{"uid":{"stringValue":"u1"}}}"#),
                            .init(status: 200, body: #"{"fields":{"uid":{"stringValue":"other"}}}"#)]
        let client = makeClient(server)
        #expect(await client.nametagAvailability(key: "모험가#0042", uid: "u1") == .available)
        #expect(await client.nametagAvailability(key: "모험가#0042", uid: "u1") == .taken)
        // 한글·`#` 문서 ID는 퍼센트 인코딩해 보낸다(#은 %23 — 안 하면 URL 조각으로 잘린다).
        #expect(server.requests[0].url?.absoluteString.contains("nametags/%EB%AA%A8%ED%97%98%EA%B0%80%230042") == true)
    }

    @Test func failedCommitRechecksReservation() async {
        let server = FakeFirestore()
        server.responses = [.init(status: 400), .init(status: 200, body: #"{"fields":{"uid":{"stringValue":"other"}}}"#)]
        let client = makeClient(server)
        let result = await client.commit(client.documents.create(uid: "u1", profile: profile),
                                         uid: "u1", nametagKey: "slime왕#0042")
        #expect(result == .taken)
        #expect(server.requests[0].httpMethod == "POST")
        #expect(server.requests[0].url?.path.hasSuffix("/documents:commit") == true)
        #expect(server.requests[1].httpMethod == "GET")
    }

    @Test func failedCommitWithoutConflictIsFailure() async {
        let server = FakeFirestore()
        server.responses = [.init(status: 503)]
        let client = makeClient(server)
        #expect(await client.commit(client.documents.changeAvatar(uid: "u1", avatarID: "cat", nowMs: 1), uid: "u1") == .failed)
    }
}

/// 요청을 기록하고 미리 넣은 응답을 차례로 돌려주는 가짜 Firestore.
@MainActor
final class FakeFirestore {
    struct Response {
        var status: Int
        var body: String = "{}"
        var date: String? = "Sun, 06 Nov 1994 08:49:37 GMT"
    }

    var responses: [Response] = []
    private(set) var requests: [URLRequest] = []

    func handle(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let r = responses.isEmpty ? Response(status: 500) : responses.removeFirst()
        var headers = ["Content-Type": "application/json"]
        headers["Date"] = r.date
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (Data(r.body.utf8), http)
    }
}
