//
//  MonsterDraw.swift
//  TokenWatch
//
//  게스트(로그인 안 함·동의 전) 출현 추첨과, 양쪽이 같이 쓰는 종 추첨·위치 계산. 순수 함수.
//  로그인 사용자의 출현·종·처치는 서버가 판정하므로(§8-4) 이 파일은 게스트 몬스터와 표시만 결정한다.
//  추첨은 키에서 결정적으로 뽑는다 — 새로고침을 반복해도 같은 추첨·세션은 같은 결과다.
//

import Foundation

enum MonsterDraw {
    /// 텍스트 → [0, 1) 결정적 난수(SHA-256 앞 8바이트).
    static func unitRoll(_ text: String) -> Double {
        let hex = MonsterSessionKey.sha256Hex(text)
        let value = UInt64(hex.prefix(16), radix: 16) ?? 0
        return Double(value >> 11) / Double(UInt64(1) << 53)
    }

    /// 이번 앱이 그릴 수 있는 일반 추첨 후보(공개·최소 버전 충족).
    static func pool(config: MonsterConfig, appVersion: String, commonOnly: Bool) -> [MonsterCatalogEntry] {
        config.catalog.filter { entry in
            entry.released && entry.weight > 0
                && (entry.minAppVersion.map { AppVersionCompare.isAtLeast(appVersion, minimum: $0) } ?? true)
                && (!commonOnly || entry.isCommon)
        }
    }

    /// 가중치 추첨. 후보가 없으면 슬라임.
    static func pick(config: MonsterConfig, appVersion: String, commonOnly: Bool, roll: Double) -> MonsterCatalogEntry {
        var candidates = pool(config: config, appVersion: appVersion, commonOnly: commonOnly)
        if candidates.isEmpty, commonOnly { candidates = pool(config: config, appVersion: appVersion, commonOnly: false) }
        let total = candidates.reduce(0) { $0 + $1.weight }
        guard total > 0 else {
            return config.entry("slime") ?? MonsterConfig.bundledDefault.catalog[0]
        }
        var target = min(max(roll, 0), 0.999_999_999) * total
        for entry in candidates {
            if target < entry.weight { return entry }
            target -= entry.weight
        }
        return candidates[candidates.count - 1]
    }

    /// 세션 창(5시간)에 붙는 슬라임 — HP·점수가 다른 별도 종이다(사용자 확정 2026-10-28).
    static let sessionSlimeID = "slime-sky"

    /// 뽑힌 종을 창에 맞춘다: 세션 창의 슬라임은 파랑 슬라임. 카탈로그에 공개돼 있고 이 앱 버전이 그릴 수 있을 때만 바꾼다(서버와 같은 규칙).
    static func forWindow(_ entry: MonsterCatalogEntry, session: Bool, config: MonsterConfig,
                          appVersion: String) -> MonsterCatalogEntry {
        guard session, entry.id == "slime", let sky = config.entry(sessionSlimeID), sky.released,
              sky.minAppVersion.map({ AppVersionCompare.isAtLeast(appVersion, minimum: $0) }) ?? true
        else { return entry }
        return sky
    }

    /// 확률 출현 몬스터의 게이지 안 위치(0.1~0.9).
    static func position(key: String) -> Double { 0.1 + unitRoll("\(key)|pos") * 0.8 }

    /// 확률 출현 몬스터의 행진 속도 배율(0.95~1.05). 같은 종 두 마리가 겹친 채 걷지 않게 한다.
    static func marchSpeed(key: String) -> Double { 0.95 + unitRoll("\(key)|speed") * 0.1 }

    /// 다음 확률 추첨까지의 간격(ms): `drawMinMinutes`~`drawMaxMinutes` 사이를 roll([0, 1))로 고른다.
    static func drawIntervalMs(config: MonsterConfig, roll: Double) -> Int64 {
        let low = Double(config.random.drawMinMinutes)
        let high = Double(max(config.random.drawMinMinutes, config.random.drawMaxMinutes))
        return Int64(((low + min(max(roll, 0), 1) * (high - low)) * 60_000).rounded(.down))
    }

    /// KST 날짜(하루 상한 경계 — 서버와 같은 기준).
    static func kstDay(nowMs: Int64) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(nowMs) / 1000))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 주간 순위의 주 — 한국 시간 월요일 0시에 시작하고, 그 주 월요일의 KST 날짜로 부른다(서버와 같은 식).
    static func kstWeekId(nowMs: Int64) -> String {
        let dayMs: Int64 = 86_400_000
        let day = (nowMs + 9 * 3_600_000) / dayMs
        let monday = day - (day + 3) % 7   // 1970-01-01은 목요일
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(monday * dayMs) / 1000))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// 게스트 출현 판정 — 서버 판정(§15-4)과 같은 규칙을 기기에서 적용한다.
enum GuestSpawnPolicy {
    enum Outcome: Equatable {
        case spawn(MonsterCatalogEntry)
        /// 확률에서 안 나옴·하루 상한·동시 생존 상한·꺼짐.
        case none
    }

    /// - Parameters:
    ///   - isCompletion: 완료 출현이면 true(확률 판정 없이 나온다).
    ///   - key: 게스트 encounter 키(`MonsterSessionKey.completionKey(uid: "guest", …)` 등).
    ///   - aliveRandom: 지금 살아 있는 게스트 확률 몬스터 수.
    static func decide(isCompletion: Bool, key: String, salt: String, config: MonsterConfig,
                       progress: MonsterGuestProgress, aliveRandom: Int, nowMs: Int64,
                       appVersion: String) -> Outcome {
        if isCompletion {
            guard config.completionEnabled else { return .none }
        } else {
            guard config.random.enabled, aliveRandom < config.random.maxAlivePerUser,
                  MonsterDraw.unitRoll("\(salt)|\(key)|chance") < config.random.chancePerSlot else { return .none }
        }
        let today = MonsterDraw.kstDay(nowMs: nowMs)
        let spawnsToday = progress.spawnDay == today ? progress.spawnsToday : 0
        guard spawnsToday < config.dailySpawnCap else { return .none }
        let commonOnly = progress.spawnCount < config.guaranteedSlimeFirstN || progress.nextCommonGuaranteed
        let entry = MonsterDraw.pick(config: config, appVersion: appVersion, commonOnly: commonOnly,
                                     roll: MonsterDraw.unitRoll("\(salt)|\(key)|species"))
        return .spawn(entry)
    }

    /// 출현이 확정됐을 때 진행 상황 갱신.
    static func recordSpawn(_ progress: inout MonsterGuestProgress, nowMs: Int64) {
        let today = MonsterDraw.kstDay(nowMs: nowMs)
        if progress.spawnDay != today {
            progress.spawnDay = today
            progress.spawnsToday = 0
        }
        progress.spawnsToday += 1
        progress.spawnCount += 1
        progress.nextCommonGuaranteed = false
    }

    /// 처치 기록. 특수 처치 직후 다음 출현은 common.
    static func recordKill(_ progress: inout MonsterGuestProgress, entry: MonsterCatalogEntry?, monsterID: String,
                           nowMs: Int64) {
        progress.kills[monsterID, default: 0] += 1
        progress.firstAtMs = progress.firstAtMs ?? nowMs
        progress.lastAtMs = nowMs
        if let entry, !entry.isCommon { progress.nextCommonGuaranteed = true }
    }
}
