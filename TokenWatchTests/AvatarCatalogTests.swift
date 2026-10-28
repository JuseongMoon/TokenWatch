//
//  AvatarCatalogTests.swift
//  TokenWatchTests
//
//  아바타 프리셋 검증 — 번들 정본 파일이 Android와 같은 바이트인지(SHA-256), 16종 ID·순서, 디코더 검사,
//  운영자 전용 아바타가 그리기 목록에만 있고 선택 격자에는 없는지.
//  비트맵을 고치면 해시 상수를 양 플랫폼에서 같이 바꾼다.
//

import Testing
import Foundation
import CryptoKit
@testable import TokenWatch

@MainActor
struct AvatarCatalogTests {
    /// 확정본(2026-10-16) `avatars-v1.json`의 SHA-256 — Android 테스트 상수와 같다.
    static let v1SHA256 = "a71c42a62000e3177983f101f1e757cb44d039ec3cae7a940d3d1396a9deffe1"
    /// 운영자 전용 `avatars-operator.json`(2026-10-19 왕관 슬라임)의 SHA-256 — Android 테스트 상수와 같다.
    static let operatorSHA256 = "b9eef2ce50a0422c3408a0d9d9eeef4950f7ee55f9d44a829e61362bbe36f2c5"
    static let v1IDs = ["warrior", "mage", "archer", "rogue", "cleric", "knight", "bard", "hacker",
                        "slime", "slime-sky", "goblin", "skeleton", "robot", "cat", "dragon", "mimic"]

    @Test func bundledFileMatchesParityHash() throws {
        let url = try #require(AvatarCatalog.bundledFileURL("avatars-v1"))
        let data = try Data(contentsOf: url)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(hex == Self.v1SHA256)
    }

    @Test func operatorFileMatchesParityHash() throws {
        let url = try #require(AvatarCatalog.bundledFileURL("avatars-operator"))
        let data = try Data(contentsOf: url)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(hex == Self.operatorSHA256)
    }

    /// 운영자 아바타는 그릴 수는 있지만 고를 수는 없다.
    @Test func operatorAvatarIsDrawableButNotSelectable() throws {
        #expect(AvatarCatalog.exclusiveFiles == ["avatars-operator"])
        let op = try #require(AvatarCatalog.operatorAvatar)
        #expect(op.id == AvatarCatalog.operatorAvatarID)
        #expect(AvatarCatalog.resolve("operator").id == "operator")
        #expect(!AvatarCatalog.ids.contains("operator"))
        #expect(AvatarCatalog.all.map(\.id) == Self.v1IDs + ["operator"])
    }

    @Test func catalogHasSixteenPresetsInOrder() {
        #expect(AvatarCatalog.bundledFiles == ["avatars-v1"])
        #expect(AvatarCatalog.ids == Self.v1IDs)
        for a in AvatarCatalog.all {
            #expect(a.sprite.frames.count == 1)
            #expect(a.sprite.rows == 16 && a.sprite.cols == 16)
            #expect(!a.nameKo.isEmpty && !a.nameEn.isEmpty)
        }
    }

    @Test func unknownIDFallsBackToSlime() {
        #expect(AvatarCatalog.resolve("pumpkin-ghoul").id == "slime")
        #expect(AvatarCatalog.resolve("dragon").id == "dragon")
    }

    @Test func randomPickIsAPublishedPreset() {
        for _ in 0..<20 { #expect(Self.v1IDs.contains(AvatarCatalog.random().id)) }
    }

    // MARK: 디코더

    private func file(grid: Int = 16, palette: String = ##"{"1":"#112233"}"##, value: Int = 1, rows: Int = 16) -> Data {
        let row = "[" + ([value] + Array(repeating: 0, count: 15)).map(String.init).joined(separator: ",") + "]"
        let frame = "[" + Array(repeating: row, count: rows).joined(separator: ",") + "]"
        return Data("""
        {"schemaVersion":1,"grid":\(grid),"future":true,"avatars":[
          {"id":"x","name":{"ko":"엑스","en":"X"},"palette":\(palette),"frames":[\(frame)],"extra":1}]}
        """.utf8)
    }

    @Test func decodesValidEntryAndIgnoresUnknownFields() throws {
        let a = try #require(AvatarDecoder.decode(file()).first)
        #expect(a.id == "x" && a.palette == [1: 0x112233] && a.bitmap[0][0] == 1)
    }

    @Test func rejectsMalformedEntries() {
        #expect(AvatarDecoder.decode(file(grid: 24)).isEmpty)                         // 격자 크기
        #expect(AvatarDecoder.decode(file(rows: 15)).isEmpty)                         // 행 수
        #expect(AvatarDecoder.decode(file(palette: ##"{"17":"#112233"}"##, value: 17)).isEmpty)  // 인덱스 상한
        #expect(AvatarDecoder.decode(file(palette: ##"{"1":"112233"}"##)).isEmpty)       // 색 형식
        #expect(AvatarDecoder.decode(file(palette: ##"{"1":"#112233"}"##, value: 2)).isEmpty)    // 팔레트에 없는 값
        #expect(AvatarDecoder.decode(Data("nope".utf8)).isEmpty)
    }

    @Test func paletteSizeHasNoFixedCap() throws {
        let palette = "{" + (1...16).map { "\"\($0)\":\"#0000" + String(format: "%02X", $0) + "\"" }.joined(separator: ",") + "}"
        let a = try #require(AvatarDecoder.decode(file(palette: palette, value: 16)).first)
        #expect(a.palette.count == 16)
    }
}
