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
//  - 서버 응답: result/error.details.code, 리더보드 runQuery 디코딩(이번 주·전체), 내 순위(주간 포함), setProfile 공개 프로필 디코딩
//  - 주간 순위의 주 경계(한국 시간 월요일 0시)
//  - 도감: 계정 처치 수 + 합친 게스트 이력 합산, 줄 세우기(공개된 종·이미 잡은 종)
//  - 데모 표본 모험가: 닉네임 규칙·순위 정렬·탭별 내 순위·도감 점수 합
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

    @Test func keys() {
        func hex(_ text: String) -> String {
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        #expect(MonsterSessionKey.completionLedgerKey(provider: .claude, resetBucketMs: 5) == "claude|5")
        // 서버 키와 같은 공식: sha256hex("{uid}|{provider}|{bucket}").
        #expect(MonsterSessionKey.completionKey(uid: "u1", provider: .claude, resetBucketMs: 1_800_000_000_000)
                == hex("u1|claude|1800000000000"))
        // 확률 출현(§15-11): sha256hex("{uid}|rand|{agentKey}|{drawAtMs}"), 에이전트 키 sha256hex("{uid}|agent|{token}").
        #expect(MonsterSessionKey.randomKey(uid: "u1", agentKey: "k", drawAtMs: 7) == hex("u1|rand|k|7"))
        #expect(MonsterSessionKey.agentKey(uid: "u1", agentToken: "t") == hex("u1|agent|t"))
        #expect(MonsterSessionKey.agentKey(uid: "u1", agentToken: "t") != MonsterSessionKey.agentKey(uid: "u2", agentToken: "t"))
        let id = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
        #expect(MonsterSessionKey.agentToken(id) == "e621e1f8-c36c-495a-93fc-0c247a3e6e5f")
    }

    @Test func drawIntervalStaysBetweenMinAndMax() {
        let c = MonsterConfig.bundledDefault
        #expect(MonsterDraw.drawIntervalMs(config: c, roll: 0) == 20 * 60_000)
        #expect(MonsterDraw.drawIntervalMs(config: c, roll: 0.5) == 30 * 60_000)
        #expect(MonsterDraw.drawIntervalMs(config: c, roll: 0.999_999) < 40 * 60_000)
        #expect(MonsterDraw.drawIntervalMs(config: c, roll: 2) == 40 * 60_000)   // 범위 밖 roll은 자른다
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
        #expect(MonsterEligibility.isRandomCandidate(full, minUsedPercent: 0, now: now))    // 100% 창도 추첨 후보
        #expect(!MonsterEligibility.isRandomCandidate(credit, minUsedPercent: 0, now: now))
    }

    @Test func accountSignatureSeparatesDifferentAccounts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3600)
        let a = [UsageWindow(label: "s", usedPercent: 40, resetsAt: reset, kind: .session),
                 UsageWindow(label: "w", usedPercent: 12, resetsAt: reset.addingTimeInterval(86_400), kind: .weekly)]
        let sig = { (p: AgentProvider, w: [UsageWindow]) in MonsterEligibility.accountSignature(provider: p, windows: w, now: now) }
        #expect(sig(.claude, a) == sig(.claude, a.reversed()))                        // 창 순서 무관
        let jitter = [UsageWindow(label: "s", usedPercent: 40.2, resetsAt: reset.addingTimeInterval(20), kind: .session), a[1]]
        #expect(sig(.claude, a) == sig(.claude, jitter))                              // 리셋 초 흔들림·소수점은 같은 계정
        let used = [UsageWindow(label: "s", usedPercent: 55, resetsAt: reset, kind: .session), a[1]]
        #expect(sig(.claude, a) != sig(.claude, used))                                // 사용률이 다르면 다른 계정
        #expect(sig(.claude, a) != sig(.codex, a))                                    // 서비스가 다르면 다른 계정
        let credit = UsageWindow(label: "c", usedPercent: 30, resetsAt: reset, kind: .weekly, style: .creditGauge)
        #expect(sig(.claude, a) == sig(.claude, a + [credit]))                        // 대상이 아닌 창은 보지 않는다
    }

    // MARK: 설정

    @Test func configEnvelopeAndDefaults() throws {
        let payload = #"{"balanceVersion":7,"spawn":{"random":{"chancePerSlot":1.5,"drawMinMinutes":3,"drawMaxMinutes":2,"slotMinutes":30}},"dailySpawnCap":10,"future":1}"#
        let envelope = try JSONSerialization.data(withJSONObject: ["fields": ["payload": ["stringValue": payload]]])
        let c = try #require(MonsterConfigDecoder.decodeEnvelope(envelope))
        #expect(c.balanceVersion == 7)
        #expect(c.random.chancePerSlot == 1)          // 0~1로 보정
        #expect(c.random.drawMinMinutes == 5)         // 최소 5분
        #expect(c.random.drawMaxMinutes == 5)         // 최대는 최소 이상
        #expect(c.random.maxAgentsPerUser == 10)      // 빠진 필드는 기본값
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
        #expect(MonsterSprites.deathSprite(for: "slime") != nil)
        #expect(MonsterSprites.deathSprite(for: "slime-sky") != nil)
        #expect(MonsterSprites.deathSprite(for: "pumpkin") == nil)
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

    @Test func sessionBarSlimeBecomesTheBlueSlime() throws {
        var c = MonsterConfig.bundledDefault
        let slime = try #require(c.entry("slime"))
        let goblin = try #require(c.entry("goblin"))
        let sky = MonsterDraw.forWindow(slime, session: true, config: c, appVersion: "2.0.0")
        #expect(sky.id == "slime-sky" && sky.hp == 2 && sky.score == 15 && sky.isCommon)
        #expect(MonsterDraw.forWindow(slime, session: false, config: c, appVersion: "2.0.0").id == "slime")
        #expect(MonsterDraw.forWindow(goblin, session: true, config: c, appVersion: "2.0.0").id == "goblin")
        // 파랑 슬라임은 weight 0이라 직접 뽑히지 않는다.
        for roll in stride(from: 0.0, to: 1.0, by: 0.01) {
            #expect(MonsterDraw.pick(config: c, appVersion: "2.0", commonOnly: false, roll: roll).id != "slime-sky")
            #expect(MonsterDraw.pick(config: c, appVersion: "2.0", commonOnly: true, roll: roll).id == "slime")
        }
        // 카탈로그에 없거나 비공개거나 이 앱이 못 그리면 슬라임 그대로.
        c.catalog = c.catalog.map { $0.id == "slime-sky" ? MonsterCatalogEntry(id: $0.id, tier: $0.tier, hp: $0.hp,
                                                                               score: $0.score, weight: 0, released: false) : $0 }
        #expect(MonsterDraw.forWindow(slime, session: true, config: c, appVersion: "2.0.0").id == "slime")
        c.catalog = c.catalog.map { $0.id == "slime-sky" ? MonsterCatalogEntry(id: $0.id, tier: $0.tier, hp: $0.hp,
                                                                               score: $0.score, weight: 0, minAppVersion: "9.0") : $0 }
        #expect(MonsterDraw.forWindow(slime, session: true, config: c, appVersion: "2.0.0").id == "slime")
        c.catalog.removeAll { $0.id == "slime-sky" }
        #expect(MonsterDraw.forWindow(slime, session: true, config: c, appVersion: "2.0.0").id == "slime")
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

    /// 주간 순위의 주는 한국 시간 월요일 0시에 바뀌고, 그 주 월요일 KST 날짜로 부른다(서버와 같은 식).
    @Test func kstWeekBoundary() {
        #expect(MonsterDraw.kstWeekId(nowMs: 1_792_335_600_000) == "2026-10-19")   // 월 00:00 KST
        #expect(MonsterDraw.kstWeekId(nowMs: 1_792_940_399_000) == "2026-10-19")   // 일 23:59:59 KST
        #expect(MonsterDraw.kstWeekId(nowMs: 1_792_940_400_000) == "2026-10-26")   // 다음 월 00:00 KST
        #expect(MonsterDraw.kstWeekId(nowMs: 1_792_335_599_000) == "2026-10-12")   // 그 직전(일요일 밤)
    }

    @Test func positionStaysInsideTheBar() {
        for i in 0..<200 {
            let p = MonsterDraw.position(key: "k\(i)")
            #expect(p >= 0.1 && p <= 0.9)
        }
    }

    @Test func marchSpeedIsDeterministicWithinFivePercent() {
        for i in 0..<200 {
            let s = MonsterDraw.marchSpeed(key: "k\(i)")
            #expect(s >= 0.95 && s <= 1.05)
            #expect(s == MonsterDraw.marchSpeed(key: "k\(i)"))
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
        let rows = try #require(MonsterAPIClient.decodeLeaderboard(Data(json.utf8), scope: .allTime))
        #expect(rows.count == 1)
        #expect(rows[0] == LeaderboardEntry(uid: "uid1", nickname: "David", tag: "0000", avatarID: "operator",
                                            score: 420, reachedAtMs: 5, commonKills: 7, specialKills: 2))
        // 주간 필드가 없는 문서는 이번 주 탭에서 버린다.
        #expect(MonsterAPIClient.decodeLeaderboard(Data(json.utf8), scope: .week)?.isEmpty == true)
    }

    @Test func weeklyLeaderboardUsesWeekFields() throws {
        let json = """
        [{"document":{"name":"projects/p/databases/(default)/documents/leaderboard/uid2","fields":{
          "nickname":{"stringValue":"Rick"},"tag":{"stringValue":"7122"},"avatar":{"stringValue":"cat"},
          "totalScore":{"integerValue":"900"},"scoreReachedAtMs":{"integerValue":"5"},
          "commonKills":{"integerValue":"70"},"specialKills":{"integerValue":"9"},
          "weekId":{"stringValue":"2026-10-19"},"weekScore":{"integerValue":"60"},"weekReachedAtMs":{"integerValue":"8"},
          "weekCommonKills":{"integerValue":"10"},"weekSpecialKills":{"integerValue":"1"}}}}]
        """
        let rows = try #require(MonsterAPIClient.decodeLeaderboard(Data(json.utf8), scope: .week))
        #expect(rows == [LeaderboardEntry(uid: "uid2", nickname: "Rick", tag: "7122", avatarID: "cat",
                                          score: 60, reachedAtMs: 8, commonKills: 10, specialKills: 1)])

        let query = try #require(MonsterAPIClient.leaderboardQuery(.week, weekID: "2026-10-19", limit: 500)["structuredQuery"]
                                 as? [String: Any])
        #expect(query["limit"] as? Int == 10)
        let filter = try #require((query["where"] as? [String: Any])?["fieldFilter"] as? [String: Any])
        #expect((filter["field"] as? [String: Any])?["fieldPath"] as? String == "weekId")
        #expect((filter["value"] as? [String: Any])?["stringValue"] as? String == "2026-10-19")
        let order = try #require(query["orderBy"] as? [[String: Any]])
        #expect(order.compactMap { ($0["field"] as? [String: Any])?["fieldPath"] as? String } == ["weekScore", "weekReachedAtMs"])
        let all = try #require(MonsterAPIClient.leaderboardQuery(.allTime, weekID: "2026-10-19", limit: 100)["structuredQuery"]
                               as? [String: Any])
        #expect(all["where"] == nil)
    }

    @Test func myRankDecodesWeek() {
        let r = MonsterAPIClient.decodeMyRank([
            "listed": true, "rank": 3, "totalScore": 900, "commonKills": 70, "specialKills": 9,
            "week": ["weekId": "2026-10-19", "listed": true, "rank": 1, "score": 60, "commonKills": 10, "specialKills": 1],
        ])
        #expect(r.rank == 3 && r.stats.totalScore == 900)
        #expect(r.week == MyRankDTO.Week(weekID: "2026-10-19", listed: true, rank: 1, score: 60, commonKills: 10, specialKills: 1))
        // 주간 값을 아직 주지 않는 서버 — 이번 주는 순위 없음.
        #expect(MonsterAPIClient.decodeMyRank(["listed": false, "totalScore": 0]).week == MyRankDTO.Week())
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

    // MARK: 도감

    @Test func bestiaryKillsSumAccountAndMergedGuestHistory() throws {
        let json = """
        {"name":"projects/p/databases/(default)/documents/players/u1","fields":{
          "stats":{"mapValue":{"fields":{"kills":{"mapValue":{"fields":{
            "slime":{"integerValue":"12"},"goblin":{"integerValue":"2"},"orc":{"integerValue":"0"}}}}}}},
          "guestHistory":{"mapValue":{"fields":{"kills":{"mapValue":{"fields":{
            "slime":{"integerValue":"3"},"mimic":{"integerValue":"1"}}}}}}}}}
        """
        #expect(MonsterAPIClient.decodeKills(Data(json.utf8)) == ["slime": 15, "goblin": 2, "mimic": 1])
        // 아직 아무것도 잡지 않은 계정: 마스크 필드가 없으면 `fields` 자체가 빠진다.
        #expect(MonsterAPIClient.decodeKills(Data(#"{"name":"projects/p/databases/(default)/documents/players/u1"}"#.utf8)) == [:])
        #expect(MonsterAPIClient.decodeKills(Data("[]".utf8)) == nil)
    }

    @Test func bestiaryListsReleasedAndAlreadyDefeatedSpecies() {
        var config = MonsterConfig.bundledDefault
        config.catalog.append(MonsterCatalogEntry(id: "dragon", tier: "event", hp: 20, score: 900, weight: 0,
                                                  released: false))
        config.catalog.append(MonsterCatalogEntry(id: "wyvern", tier: "special", hp: 9, score: 300, weight: 1,
                                                  minAppVersion: "9.0"))
        let rows = MonsterBestiary.rows(config: config, kills: ["slime": 4, "orc": 1], appVersion: "1.4.0")
        #expect(rows.map(\.id) == ["slime", "slime-sky", "goblin", "skeleton", "orc", "mimic"])
        #expect(rows.filter(\.discovered).map(\.id) == ["slime", "orc"])
        #expect(rows.first { $0.id == "goblin" }?.kills == 0)
        // 공개 전 종·이 앱이 못 그리는 종도 이미 잡았으면 보인다.
        let caught = MonsterBestiary.rows(config: config, kills: ["dragon": 1, "wyvern": 2], appVersion: "1.4.0")
        #expect(caught.suffix(2).map(\.id) == ["dragon", "wyvern"])
    }

    // MARK: 데모 표본 모험가

    @Test func demoAdventureIsSelfConsistent() throws {
        for lang in [Lang.ko, .en] {
            let me = DemoAdventure.profile(lang)
            #expect(NicknamePolicy.validate(me.nickname) == nil && NicknamePolicy.isValidTag(me.tag))
            #expect(AvatarCatalog.ids.contains(me.avatarID))
            for scope in LeaderboardScope.allCases {
                let rows = DemoAdventure.leaderboard(scope, lang: lang)
                #expect(rows.count == MonsterAPIClient.leaderboardSize)
                #expect(rows.map(\.score) == rows.map(\.score).sorted(by: >))
                #expect(Set(rows.map(\.uid)).count == rows.count)
                let line = DemoAdventure.mine(scope)
                let mine = try #require(rows.firstIndex { $0.uid == DemoAdventure.uid })
                #expect(mine + 1 == line.rank && rows[mine].score == line.score)
                #expect(rows[mine].nickname == me.nickname && rows[mine].avatarID == me.avatarID)
                for row in rows {   // 표본 이름도 닉네임 규칙·프리셋 아바타를 지킨다
                    #expect(NicknamePolicy.validate(row.nickname) == nil, "\(row.nickname)")
                    #expect(AvatarCatalog.ids.contains(row.avatarID), "\(row.avatarID)")
                }
            }
        }
        // 도감 처치 수의 점수 합 = 전체 탭 내 점수, 슬라임·고블린 말고는 아직 못 잡은 실루엣.
        let config = MonsterConfig.bundledDefault
        let points = DemoAdventure.kills.reduce(0) { $0 + (config.entry($1.key)?.score ?? 0) * $1.value }
        #expect(points == DemoAdventure.mine(.allTime).score)
        let rows = MonsterBestiary.rows(config: config, kills: DemoAdventure.kills, appVersion: "2.0.0")
        #expect(rows.filter { !$0.discovered }.map(\.id) == ["slime-sky", "skeleton", "orc", "mimic"])
    }
}

extension Result where Failure == MonsterAPIClient.CallError {
    /// 서버 오류 코드(없으면 nil).
    var failureCode: String? {
        if case .failure(.server(let code)) = self { return code }
        return nil
    }
}
