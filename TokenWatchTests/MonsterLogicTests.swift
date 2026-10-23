//
//  MonsterLogicTests.swift
//  TokenWatchTests
//
//  몬스터(V2) 순수 로직 검증 — Android와 같은 값이 나와야 하는 것들은 상수로 고정한다.
//  - 세션 키: 300초 반올림, Copilot UTC 자정, Codex 추가 한도 label 상수, 주기 표(windowSeconds → 월간 → 기본)
//  - 슬롯·키 해시·대상 창 판정(게이지·미래 리셋·완료 0.995)
//  - 설정 디코딩: 봉투, 빠진 필드는 기본값, 범위 보정, 잘못된 카탈로그 항목 버림
//  - 스프라이트: 번들 파일 SHA-256 parity, 6종 크기, inline 상한, 흑백톤 공식
//  - 추첨: 가중치 경계, common 보장, 최소 버전, 게스트 하루 상한·확률·동시 생존
//  - 서버 응답: result/error.details.code, 리더보드 runQuery 디코딩, setProfile 공개 프로필 디코딩
//

import CryptoKit
import Foundation
import Testing
@testable import TokenWatch

@MainActor
struct MonsterLogicTests {
    // MARK: 세션 키

    @Test func resetBucketRoundsToFiveMinutes() {
        #expect(MonsterSessionKey.resetBucketMs(1_800_000_149_999) == 1_800_000_000_000)
        #expect(MonsterSessionKey.resetBucketMs(1_800_000_150_000) == 1_800_000_300_000)
        #expect(MonsterSessionKey.resetBucketMs(1_799_999_999_400) == 1_800_000_000_000)
    }

    @Test func copilotUsesUTCMidnightOfTheLocalDate() {
        // 서울 기기에서 "2026-11-01"을 자정으로 파싱한 값 → 키는 2026-11-01T00:00Z.
        let seoul = TimeZone(identifier: "Asia/Seoul")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = seoul
        let local = cal.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        #expect(MonsterSessionKey.keyResetsAtMs(provider: .copilot, resetsAt: local, timeZone: seoul) == 1_793_491_200_000)
        // 다른 provider는 그대로.
        #expect(MonsterSessionKey.keyResetsAtMs(provider: .claude, resetsAt: local, timeZone: seoul)
                == MonsterSessionKey.epochMs(local))
    }

    @Test func codexFallbackLabelIsLanguageFree() {
        #expect(MonsterSessionKey.keyLabel(provider: .codex, label: "추가 한도") == "Additional limit")
        #expect(MonsterSessionKey.keyLabel(provider: .codex, label: "Additional limit") == "Additional limit")
        #expect(MonsterSessionKey.keyLabel(provider: .codex, label: "GPT-5 Pro") == "GPT-5 Pro")
        #expect(MonsterSessionKey.keyLabel(provider: .claude, label: "추가 한도") == "추가 한도")
    }

    /// 주기 계산표 — Android 테스트와 같은 값(계약 §8-4).
    @Test func periodSecondsTable() {
        let month: Int64 = 2_678_400
        #expect(MonsterSessionKey.periodSec(provider: .claude, label: "Current session", windowSeconds: nil, kind: .session) == 18_000)
        #expect(MonsterSessionKey.periodSec(provider: .claude, label: "Current week (all models)", windowSeconds: nil, kind: .weekly) == 604_800)
        #expect(MonsterSessionKey.periodSec(provider: .codex, label: "Current week", windowSeconds: 604_800.4, kind: .weekly) == 604_800)
        #expect(MonsterSessionKey.periodSec(provider: .copilot, label: "Premium requests", windowSeconds: nil, kind: .weekly) == month)
        #expect(MonsterSessionKey.periodSec(provider: .copilot, label: "Something new", windowSeconds: nil, kind: .weekly) == month)
        #expect(MonsterSessionKey.periodSec(provider: .kimi, label: "Current month", windowSeconds: nil, kind: .weekly) == month)
        #expect(MonsterSessionKey.periodSec(provider: .kimi, label: "Current month (Code)", windowSeconds: nil, kind: .weekly) == month)
        #expect(MonsterSessionKey.periodSec(provider: .kimi, label: "Current week", windowSeconds: nil, kind: .weekly) == 604_800)
        #expect(MonsterSessionKey.periodSec(provider: .elevenlabs, label: "Monthly characters", windowSeconds: nil, kind: .weekly) == month)
    }

    @Test func slotsAndKeys() {
        #expect(MonsterSessionKey.slotStartMs(nowMs: 1_800_003_599_999, slotMinutes: 60) == 1_800_000_000_000)
        #expect(MonsterSessionKey.completionLedgerKey(provider: .claude, resetBucketMs: 5) == "claude|5")
        #expect(MonsterSessionKey.randomLedgerKey(slotStartMs: 7) == "rand|7")
        // 서버 키와 같은 공식: sha256hex("{uid}|{provider}|{bucket}").
        let expected = SHA256.hash(data: Data("u1|claude|1800000000000".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(MonsterSessionKey.completionKey(uid: "u1", provider: .claude, resetBucketMs: 1_800_000_000_000) == expected)
        #expect(MonsterSessionKey.randomKey(uid: "u1", slotStartMs: 1) != MonsterSessionKey.randomKey(uid: "u2", slotStartMs: 1))
    }

    @Test func eligibility() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = now.addingTimeInterval(3600)
        let full = UsageWindow(label: "w", usedPercent: 99.5, resetsAt: future, kind: .weekly)
        let half = UsageWindow(label: "w", usedPercent: 40, resetsAt: future, kind: .weekly)
        let past = UsageWindow(label: "w", usedPercent: 100, resetsAt: now.addingTimeInterval(-1), kind: .weekly)
        let noReset = UsageWindow(label: "w", usedPercent: 100, resetsAt: nil, kind: .weekly)
        let credit = UsageWindow(label: "w", usedPercent: 100, resetsAt: future, kind: .weekly, style: .creditGauge)
        #expect(MonsterEligibility.isCompleted(full, now: now))
        #expect(!MonsterEligibility.isCompleted(half, now: now))
        #expect(!MonsterEligibility.isTarget(past, now: now) && !MonsterEligibility.isTarget(noReset, now: now))
        #expect(!MonsterEligibility.isTarget(credit, now: now))
        #expect(MonsterEligibility.isRandomCandidate(half, minUsedPercent: 0, now: now))
        #expect(!MonsterEligibility.isRandomCandidate(half, minUsedPercent: 50, now: now))
        #expect(!MonsterEligibility.isRandomCandidate(full, minUsedPercent: 0, now: now))   // 완료 창은 완료 몬스터 몫
    }

    // MARK: 설정

    @Test func configEnvelopeAndDefaults() throws {
        let payload = #"{"balanceVersion":7,"spawn":{"random":{"chancePerSlot":1.5,"slotMinutes":30}},"dailySpawnCap":10,"future":1}"#
        let envelope = try JSONSerialization.data(withJSONObject: ["fields": ["payload": ["stringValue": payload]]])
        let c = try #require(MonsterConfigDecoder.decodeEnvelope(envelope))
        #expect(c.balanceVersion == 7)
        #expect(c.random.chancePerSlot == 1)          // 0~1로 보정
        #expect(c.random.slotMinutes == 30)
        #expect(c.random.lifetimeMinutes == 60)       // 빠진 필드는 기본값
        #expect(c.dailySpawnCap == 10)
        #expect(c.catalog == MonsterConfig.bundledDefault.catalog)
        #expect(MonsterConfigDecoder.decodePayload(Data("[1]".utf8)) == nil)
    }

    @Test func catalogDropsBrokenEntries() throws {
        let payload = #"{"catalog":[{"id":"bat","tier":"special","hp":2,"score":30,"weight":3,"released":false,"minAppVersion":"9.0"},{"id":"","hp":1,"score":1},{"id":"x","hp":0,"score":1}]}"#
        let c = try #require(MonsterConfigDecoder.decodePayload(Data(payload.utf8)))
        #expect(c.catalog.map(\.id) == ["bat"])
        #expect(c.catalog[0].released == false && c.catalog[0].minAppVersion == "9.0")
    }

    @Test func appVersionCompare() {
        #expect(AppVersionCompare.isAtLeast("1.10", minimum: "1.4.0"))
        #expect(AppVersionCompare.isAtLeast("1.4", minimum: "1.4.0"))
        #expect(!AppVersionCompare.isAtLeast("1.3.9", minimum: "1.4"))
    }

    // MARK: 스프라이트

    /// 번들 `monsters-v1.json`의 SHA-256 — Android 테스트 상수와 같다.
    static let spritesSHA256 = "6c33cfb59dbcec67a0282d942a60d26eb2d5fde1adb1e05f12fd585b81ebbd06"

    @Test func bundledSpritesMatchParityHash() throws {
        let url = try #require(Bundle.main.url(forResource: MonsterSprites.bundledFile, withExtension: "json"))
        let hex = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        #expect(hex == Self.spritesSHA256)
        let sprites = MonsterSprites.bundled
        #expect(Set(sprites.keys) == ["goblin", "skeleton", "orc", "mimic", "fx-sword", "fx-halo",
                                      "slime-death", "slime-sky-death", "goblin-death", "skeleton-death",
                                      "orc-death", "mimic-death"])
        for id in ["goblin", "skeleton", "orc", "mimic"] {
            let s = try #require(sprites[id])
            let death = try #require(sprites["\(id)-death"])
            #expect(s.frames.count == 2 && s.rows == 8)
            // 사망 애니메이션은 몬스터와 같은 크기(같은 자리에서 이어지게) 4프레임.
            #expect(death.frames.count == 4 && death.rows == s.rows && death.cols == s.cols)
        }
        #expect(sprites["slime-death"]?.rows == PixelSprite.slime.rows && sprites["slime-death"]?.cols == PixelSprite.slime.cols)
        #expect(MonsterSprites.deathSprite(for: "slime", sessionWindow: true) != nil)
        #expect(MonsterSprites.deathSprite(for: "pumpkin", sessionWindow: false) == nil)
    }

    @Test func inlineSpriteLimits() {
        let ok: [String: Any] = ["cols": 2, "rows": 1, "frames": [[[1, 0]]], "palette": ["1": "#FF0000"]]
        #expect(MonsterSpriteDecoder.decodeInline(ok) != nil)
        var wrongSize = ok
        wrongSize["cols"] = 3
        #expect(MonsterSpriteDecoder.decodeInline(wrongSize) == nil)
        let tooWide: [String: Any] = ["cols": 25, "rows": 1, "frames": [[Array(repeating: 0, count: 25)]], "palette": [:] as [String: String]]
        #expect(MonsterSpriteDecoder.decodeInline(tooWide) == nil)
        let missingColor: [String: Any] = ["cols": 1, "rows": 1, "frames": [[[2]]], "palette": ["1": "#FF0000"]]
        #expect(MonsterSpriteDecoder.decodeInline(missingColor) == nil)
    }

    @Test func grayToneFormula() {
        // 빨강 F0574C → Y = (0.299·240 + 0.587·87 + 0.114·76)·0.8 = 105.19… → 105(0x69). Android와 같은 값.
        #expect(MonsterSpriteDecoder.grayTone(0xF0574C) == 0x696969)
        #expect(MonsterSpriteDecoder.grayTone(0xFFFFFF) == 0xCCCCCC)
        #expect(MonsterSpriteDecoder.grayTone(0x000000) == 0)
    }

    // MARK: 추첨

    @Test func weightedPickBoundaries() {
        let c = MonsterConfig.bundledDefault   // 90 / 6 / 2.5 / 1 / 0.5 = 100
        #expect(MonsterDraw.pick(config: c, appVersion: "2.0", commonOnly: false, roll: 0).id == "slime")
        #expect(MonsterDraw.pick(config: c, appVersion: "2.0", commonOnly: false, roll: 0.8999).id == "slime")
        #expect(MonsterDraw.pick(config: c, appVersion: "2.0", commonOnly: false, roll: 0.9).id == "goblin")
        #expect(MonsterDraw.pick(config: c, appVersion: "2.0", commonOnly: false, roll: 0.9999).id == "mimic")
        #expect(MonsterDraw.pick(config: c, appVersion: "2.0", commonOnly: true, roll: 0.9999).id == "slime")
    }

    @Test func unreleasedAndNewerMonstersAreSkipped() {
        var c = MonsterConfig.bundledDefault
        c.catalog = [MonsterCatalogEntry(id: "slime", tier: "common", hp: 1, score: 10, weight: 1),
                     MonsterCatalogEntry(id: "bat", tier: "special", hp: 2, score: 30, weight: 99, released: false),
                     MonsterCatalogEntry(id: "imp", tier: "special", hp: 2, score: 30, weight: 99, minAppVersion: "9.0")]
        for roll in [0.0, 0.5, 0.99] {
            #expect(MonsterDraw.pick(config: c, appVersion: "2.0", commonOnly: false, roll: roll).id == "slime")
        }
    }

    @Test func guestPolicyGuaranteesAndCaps() {
        var c = MonsterConfig.bundledDefault
        var progress = MonsterGuestProgress()
        let now: Int64 = 1_800_000_000_000
        // 첫 3회는 common.
        for i in 0..<3 {
            guard case .spawn(let e) = GuestSpawnPolicy.decide(isCompletion: true, key: "k\(i)", salt: "s", config: c,
                                                               progress: progress, aliveRandom: 0, nowMs: now,
                                                               appVersion: "2.0") else { Issue.record("no spawn"); return }
            #expect(e.isCommon)
            GuestSpawnPolicy.recordSpawn(&progress, nowMs: now)
        }
        // 특수 처치 직후 다음은 common.
        GuestSpawnPolicy.recordKill(&progress, entry: c.entry("orc"), monsterID: "orc", nowMs: now)
        #expect(progress.nextCommonGuaranteed && progress.kills["orc"] == 1)
        guard case .spawn(let next) = GuestSpawnPolicy.decide(isCompletion: true, key: "z", salt: "s", config: c,
                                                              progress: progress, aliveRandom: 0, nowMs: now,
                                                              appVersion: "2.0") else { Issue.record("no spawn"); return }
        #expect(next.isCommon)
        // 하루 상한.
        c.dailySpawnCap = 3
        #expect(GuestSpawnPolicy.decide(isCompletion: true, key: "y", salt: "s", config: c, progress: progress,
                                        aliveRandom: 0, nowMs: now, appVersion: "2.0") == .none)
        // 확률 0이면 확률 출현 없음, 동시 생존 상한.
        c = .bundledDefault
        c.random.chancePerSlot = 0
        #expect(GuestSpawnPolicy.decide(isCompletion: false, key: "r", salt: "s", config: c, progress: MonsterGuestProgress(),
                                        aliveRandom: 0, nowMs: now, appVersion: "2.0") == .none)
        c.random.chancePerSlot = 1
        #expect(GuestSpawnPolicy.decide(isCompletion: false, key: "r", salt: "s", config: c, progress: MonsterGuestProgress(),
                                        aliveRandom: 3, nowMs: now, appVersion: "2.0") == .none)
    }

    @Test func kstDayBoundary() {
        // 2026-10-19T14:59:59Z = KST 23:59:59, 15:00:00Z = KST 다음 날.
        #expect(MonsterDraw.kstDay(nowMs: 1_792_421_999_000) == "2026-10-19")
        #expect(MonsterDraw.kstDay(nowMs: 1_792_422_000_000) == "2026-10-20")
    }

    @Test func positionStaysInsideTheBar() {
        for i in 0..<200 {
            let p = MonsterDraw.position(key: "k\(i)")
            #expect(p >= 0.1 && p <= 0.9)
        }
    }

    // MARK: 서버 응답

    @Test func callResponseDecoding() {
        let ok = MonsterAPIClient.decodeCallResponse(Data(#"{"result":{"a":1}}"#.utf8), status: 200)
        #expect((try? ok.get())?["a"] as? Int == 1)
        let err = MonsterAPIClient.decodeCallResponse(
            Data(#"{"error":{"status":"FAILED_PRECONDITION","message":"secret text","details":{"code":"consent_required"}}}"#.utf8),
            status: 400)
        #expect(err.failureCode == "consent_required")
        let noDetails = MonsterAPIClient.decodeCallResponse(Data(#"{"error":{"status":"UNAUTHENTICATED"}}"#.utf8), status: 401)
        #expect(noDetails.failureCode == "unauthenticated")
        #expect(MonsterAPIClient.decodeCallResponse(Data("x".utf8), status: 500).failureCode == nil)
    }

    @Test func leaderboardDecoding() throws {
        let json = """
        [{"document":{"name":"projects/p/databases/(default)/documents/leaderboard/uid1","fields":{
          "nickname":{"stringValue":"David"},"tag":{"stringValue":"0000"},"avatar":{"stringValue":"operator"},
          "totalScore":{"integerValue":"420"},"scoreReachedAtMs":{"integerValue":"5"},
          "commonKills":{"integerValue":"7"},"specialKills":{"integerValue":"2"}}}},
         {"readTime":"2026-10-20T00:00:00Z"}]
        """
        let rows = try #require(MonsterAPIClient.decodeLeaderboard(Data(json.utf8)))
        #expect(rows.count == 1)
        #expect(rows[0] == LeaderboardEntry(uid: "uid1", nickname: "David", tag: "0000", avatarID: "operator",
                                            totalScore: 420, scoreReachedAtMs: 5, commonKills: 7, specialKills: 2))
    }

    /// 게스트 이력은 종별 합계 500까지만 보낸다(많이 잡은 종부터).
    @Test func guestHistoryIsCapped() {
        let capped = MonsterAPIClient.cappedKills(["slime": 480, "goblin": 30, "orc": 2])
        #expect(capped.values.reduce(0, +) == 500)
        #expect(capped == ["slime": 480, "goblin": 20])
        #expect(MonsterAPIClient.cappedKills(["slime": 3]) == ["slime": 3])
    }

    @Test func encounterDTODecoding() {
        let dto = MonsterEncounterDTO(json: ["key": "k", "source": "completion", "provider": "claude",
                                             "windowLabel": "Current week", "resetBucketMs": "1800000000000",
                                             "monsterId": "goblin", "maxHP": 3, "state": "alive",
                                             "spawnedAtMs": 1, "expiresAtMs": 2])
        #expect(dto?.resetBucketMs == 1_800_000_000_000 && dto?.maxHP == 3)
        #expect(MonsterEncounterDTO(json: ["key": "k"]) == nil)
    }

    /// `setProfile` 응답의 공개 프로필(일반 JSON) 디코딩.
    @Test func callableProfileDecoding() throws {
        let json: [String: Any] = ["nickname": "Slime왕", "nicknameLower": "slime왕", "tag": "0042",
                                   "nicknameChangedAtMs": 1_700_000_000_000, "avatar": ["kind": "preset", "id": "mage"],
                                   "termsAcceptedVersion": 2, "createdAtMs": 1_690_000_000_000,
                                   "updatedAtMs": 1_700_000_000_001]
        #expect(MonsterAPIClient.decodeProfile(json) == PlayerProfile(
            nickname: "Slime왕", nicknameLower: "slime왕", tag: "0042", nicknameChangedAtMs: 1_700_000_000_000,
            avatarID: "mage", termsAcceptedVersion: 2, createdAtMs: 1_690_000_000_000, updatedAtMs: 1_700_000_000_001))
        // V1 계정: 약관 버전이 없으면 0, 프리셋이 아닌 아바타는 기본 아바타.
        var legacy = json
        legacy["termsAcceptedVersion"] = nil
        legacy["avatar"] = ["kind": "photo"]
        let p = try #require(MonsterAPIClient.decodeProfile(legacy))
        #expect(p.termsAcceptedVersion == 0 && p.avatarID == AvatarCatalog.fallbackID)
        legacy["tag"] = "42"
        #expect(MonsterAPIClient.decodeProfile(legacy) == nil)
    }
}

extension Result where Failure == MonsterAPIClient.CallError {
    /// 서버 오류 코드(없으면 nil).
    var failureCode: String? {
        if case .failure(.server(let code)) = self { return code }
        return nil
    }
}
