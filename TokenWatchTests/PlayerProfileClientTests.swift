//
//  PlayerProfileClientTests.swift
//  TokenWatchTests
//
//  앱 계정 Firestore REST 읽기 계층 검증(계약 §3·§4). 프로필 쓰기는 서버 callable이라 AccountStoreTests가 본다.
//  - 디코딩: 모르는 필드 무시, 프리셋이 아닌 아바타는 기본 아바타, 필수 필드·태그 형식
//  - Date 헤더 시차 보정
//  - 클라이언트: Bearer 헤더·`?key=` 없음, 404/200 매핑, 401·403 → 토큰 강제 갱신 1회 재시도
//

import Testing
import Foundation
@testable import TokenWatch

@MainActor
struct PlayerProfileClientTests {
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
        server.responses = [.init(status: 403), .init(status: 404)]
        #expect(await makeClient(server).fetchProfile(uid: "u1") == .notFound)
        #expect(server.requests.map { $0.value(forHTTPHeaderField: "Authorization") } ==
                ["Bearer cached-token", "Bearer fresh-token"])
    }

    @Test func secondUnauthorizedFails() async {
        let server = FakeFirestore()
        server.responses = [.init(status: 401), .init(status: 401)]
        #expect(await makeClient(server).fetchProfile(uid: "u1") == .failed)
        #expect(server.requests.count == 2)
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
