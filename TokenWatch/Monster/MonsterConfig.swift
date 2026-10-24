//
//  MonsterConfig.swift
//  TokenWatch
//
//  몬스터 카탈로그·출현 설정(서버 `config/monster`, 관리자 페이지가 발행 — 계약 §8-5).
//  앱은 번들 기본값을 먼저 쓰고, 공개 문서를 1시간 스로틀로 받아 캐시한다. 게스트 추첨·표시에만 쓰고,
//  로그인 사용자의 출현·처치 판정 정본은 서버(Functions)가 같은 설정으로 한다.
//  모르는 필드·ID는 무시하고, 빠진 필드는 기본값으로 채운다(관리자가 일부만 바꿔도 깨지지 않게).
//

import Foundation

nonisolated struct MonsterConfig: Equatable, Sendable {
    var schemaVersion: Int
    var balanceVersion: Int
    var catalog: [MonsterCatalogEntry]
    var completionEnabled: Bool
    var random: RandomSpawn
    var guaranteedSlimeFirstN: Int
    var tapDebounceMs: Int
    var dailySpawnCap: Int

    /// 확률 출현(§15-11): 에이전트마다 `drawMinMinutes`~`drawMaxMinutes` 간격으로 한 번씩 추첨한다.
    nonisolated struct RandomSpawn: Equatable, Sendable {
        var enabled: Bool
        /// 추첨 1회당 확률(이름은 슬롯 시절 그대로).
        var chancePerSlot: Double
        var drawMinMinutes: Int
        var drawMaxMinutes: Int
        var lifetimeMinutes: Int
        var minUsedPercent: Double
        var maxAlivePerUser: Int
        /// 추첨하는 에이전트 수 상한(서버는 최근 7일에 본 에이전트로 센다).
        var maxAgentsPerUser: Int
    }

    /// 번들 기본값 — 서버 시드(계약 §8-2·§13 2026-10-19 결정)와 같은 값.
    static let bundledDefault = MonsterConfig(
        schemaVersion: 1, balanceVersion: 1,
        catalog: [
            MonsterCatalogEntry(id: "slime", tier: "common", hp: 1, score: 10, weight: 90),
            MonsterCatalogEntry(id: "goblin", tier: "special", hp: 3, score: 50, weight: 6),
            MonsterCatalogEntry(id: "skeleton", tier: "special", hp: 5, score: 100, weight: 2.5),
            MonsterCatalogEntry(id: "orc", tier: "special", hp: 8, score: 190, weight: 1),
            MonsterCatalogEntry(id: "mimic", tier: "special", hp: 12, score: 350, weight: 0.5),
        ],
        completionEnabled: true,
        random: RandomSpawn(enabled: true, chancePerSlot: 0.08, drawMinMinutes: 20, drawMaxMinutes: 40,
                            lifetimeMinutes: 60, minUsedPercent: 0, maxAlivePerUser: 3, maxAgentsPerUser: 10),
        guaranteedSlimeFirstN: 3, tapDebounceMs: 120, dailySpawnCap: 60)

    func entry(_ id: String) -> MonsterCatalogEntry? { catalog.first { $0.id == id } }
}

nonisolated struct MonsterCatalogEntry: Equatable, Sendable {
    let id: String
    /// common · special · event. 모르는 값은 special로 다룬다(리더보드 집계는 서버가 한다).
    let tier: String
    let hp: Int
    let score: Int
    let weight: Double
    var released: Bool = true
    var bundledSprite: String? = nil
    var inlineSprite: MonsterSpriteData? = nil
    var minAppVersion: String? = nil

    var isCommon: Bool { tier == "common" }
}

/// 설정 JSON 디코딩(순수 함수). 공지 피드와 같은 `payload` 문자열 봉투를 쓴다.
nonisolated enum MonsterConfigDecoder {
    static func decodeEnvelope(_ data: Data) -> MonsterConfig? {
        payloadData(data).flatMap(decodePayload)
    }

    /// Firestore 문서 봉투에서 `payload` 문자열을 꺼낸다.
    static func payloadData(_ data: Data) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fields = root["fields"] as? [String: Any],
              let payload = (fields["payload"] as? [String: Any])?["stringValue"] as? String else { return nil }
        return Data(payload.utf8)
    }

    /// payload JSON. 최상위가 객체가 아니면 nil, 필드가 빠지면 기본값.
    static func decodePayload(_ data: Data) -> MonsterConfig? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let base = MonsterConfig.bundledDefault
        var config = base
        config.schemaVersion = int(json["schemaVersion"]) ?? base.schemaVersion
        config.balanceVersion = int(json["balanceVersion"]) ?? base.balanceVersion
        if let list = json["catalog"] as? [[String: Any]] {
            let entries = list.compactMap(entry)
            if !entries.isEmpty { config.catalog = entries }
        }
        if let spawn = json["spawn"] as? [String: Any] {
            if let completion = spawn["completion"] as? [String: Any], let on = completion["enabled"] as? Bool {
                config.completionEnabled = on
            }
            if let r = spawn["random"] as? [String: Any] {
                config.random.enabled = (r["enabled"] as? Bool) ?? base.random.enabled
                config.random.chancePerSlot = clamp(double(r["chancePerSlot"]) ?? base.random.chancePerSlot, 0, 1)
                // 간격은 5분~하루, 최대는 최소 이상(서버 검증과 같은 범위).
                let drawMin = min(1440, max(5, int(r["drawMinMinutes"]) ?? base.random.drawMinMinutes))
                config.random.drawMinMinutes = drawMin
                config.random.drawMaxMinutes = min(1440, max(drawMin, int(r["drawMaxMinutes"]) ?? base.random.drawMaxMinutes))
                config.random.lifetimeMinutes = max(1, int(r["lifetimeMinutes"]) ?? base.random.lifetimeMinutes)
                config.random.minUsedPercent = double(r["minUsedPercent"]) ?? base.random.minUsedPercent
                config.random.maxAlivePerUser = max(0, int(r["maxAlivePerUser"]) ?? base.random.maxAlivePerUser)
                config.random.maxAgentsPerUser = max(0, int(r["maxAgentsPerUser"]) ?? base.random.maxAgentsPerUser)
            }
        }
        config.guaranteedSlimeFirstN = max(0, int(json["guaranteedSlimeFirstN"]) ?? base.guaranteedSlimeFirstN)
        config.tapDebounceMs = max(0, int(json["tapDebounceMs"]) ?? base.tapDebounceMs)
        config.dailySpawnCap = max(0, int(json["dailySpawnCap"]) ?? base.dailySpawnCap)
        return config
    }

    private static func entry(_ e: [String: Any]) -> MonsterCatalogEntry? {
        guard let id = e["id"] as? String, !id.isEmpty, let hp = int(e["hp"]), hp >= 1,
              let score = int(e["score"]), score >= 0 else { return nil }
        let sprite = e["sprite"] as? [String: Any]
        return MonsterCatalogEntry(
            id: id, tier: (e["tier"] as? String) ?? "special", hp: hp, score: score,
            weight: max(0, double(e["weight"]) ?? 0), released: (e["released"] as? Bool) ?? true,
            bundledSprite: sprite?["bundled"] as? String,
            inlineSprite: (sprite?["inline"] as? [String: Any]).flatMap(MonsterSpriteDecoder.decodeInline),
            minAppVersion: e["minAppVersion"] as? String)
    }

    private static func int(_ v: Any?) -> Int? {
        if let n = v as? Int { return n }
        if let d = v as? Double, d.rounded() == d { return Int(d) }
        return nil
    }

    private static func double(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? Int { return Double(n) }
        return nil
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
}

/// 앱 버전 비교("1.4.0" < "1.10"). 숫자가 아닌 조각은 0으로 본다.
nonisolated enum AppVersionCompare {
    static func isAtLeast(_ version: String, minimum: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = minimum.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }
}

/// `config/monster` 공개 문서를 읽는다(인증 없음, 공지 피드와 같은 방식).
enum MonsterConfigClient {
    /// payload JSON 원문(캐시용). 디코딩은 `MonsterConfigDecoder.decodePayload`.
    static func fetchPayload() async -> Data? {
        guard let url = documentURL() else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bundleID = Bundle.main.bundleIdentifier {
            req.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }
        req.timeoutInterval = 10
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return MonsterConfigDecoder.payloadData(data)
    }

    static func documentURL() -> URL? {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path),
              let projectID = dict["PROJECT_ID"] as? String, !projectID.isEmpty,
              let apiKey = dict["API_KEY"] as? String, !apiKey.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "firestore.googleapis.com"
        components.path = "/v1/projects/\(projectID)/databases/(default)/documents/config/monster"
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        return components.url
    }
}
