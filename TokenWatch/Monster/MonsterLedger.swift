//
//  MonsterLedger.swift
//  TokenWatch
//
//  몬스터 출현·처치 기록(기기 원장)과 계정 무관 기기 세션 장부.
//
//  - 원장: Application Support의 JSON 파일 하나(`monster-encounters.v1.json`). UserDefaults는 파일 전체를
//    다시 쓰므로 쓰지 않는다(계약 §8-7). 살아 있는 것·서버 미확정 처치·최근 처치 200건만 원본으로 두고,
//    게스트 처치는 종별 카운터로 따로 센다.
//  - 기기 세션 장부(§8-8): 이 기기에서 이미 몬스터를 받은 세션·슬롯 키 → 받은 uid. 다른 uid로 로그인했을 때
//    같은 키로 다시 요청하지 않는다(계정을 바꿔 같은 사용량으로 몬스터를 또 받는 것을 막는다).
//    Keychain(ThisDeviceOnly)에 둬서 앱을 다시 깔아도 남는다. 자격증명이 아니며 서버로 보내지 않는다.
//

import Foundation

nonisolated struct MonsterEncounter: Codable, Equatable, Sendable, Identifiable {
    enum Source: String, Codable, Sendable { case completion, random, event }
    enum State: String, Codable, Sendable { case alive, defeated, expired }

    var id: String { key }
    let key: String
    /// nil = 게스트(기기 추첨, 비순위). 값이 있으면 그 계정의 서버 판정 몬스터.
    let ownerUID: String?
    let source: Source
    let provider: String
    /// 키용 label(Codex 추가 한도는 상수).
    let windowLabel: String
    let resetBucketMs: Int64?
    let slotStartMs: Int64?
    let monsterID: String
    let maxHP: Int
    /// 남은 HP(기기 로컬 — 타격은 서버로 보내지 않는다).
    var hp: Int
    var state: State
    let spawnedAtMs: Int64
    let expiresAtMs: Int64
    var defeatedAtMs: Int64?
    var awardedScore: Int?
    /// 처치했지만 서버 확인 전(오프라인 등) — 다음 기회에 다시 보낸다.
    var pendingDefeat: Bool = false
    /// 화면에 붙일 창(이 기기의 에이전트·표시 label). 다른 기기에서 받은 몬스터는 provider·label로 다시 찾는다.
    var agentID: UUID?
    var displayLabel: String?
    /// 확률 출현의 게이지 안 위치(0~1, 키에서 결정적으로 정한다).
    var position: Double

    var isAlive: Bool { state == .alive }
}

/// 게스트 진행 상황(비순위). 첫 로그인 때 한 번 계정 이력으로 합친다(§15-7).
nonisolated struct MonsterGuestProgress: Codable, Equatable, Sendable {
    var spawnCount = 0
    var nextCommonGuaranteed = false
    var spawnDay = ""
    var spawnsToday = 0
    var kills: [String: Int] = [:]
    var firstAtMs: Int64?
    var lastAtMs: Int64?
}

nonisolated struct MonsterLedgerState: Codable, Equatable, Sendable {
    var encounters: [MonsterEncounter] = []
    var guest = MonsterGuestProgress()
    /// 게스트 이력을 이미 합친(또는 합칠 필요 없다고 확인된) 계정 uid.
    var mergedUIDs: [String] = []
    /// 설치마다 무작위 — 게스트 추첨 시드(서버로 보내지 않는다).
    var deviceSalt = UUID().uuidString

    /// 보존 상한: 살아 있는 것·미확정 처치는 모두, 끝난 것은 최근 200건.
    static let keepFinished = 200

    mutating func prune() {
        let active = encounters.filter { $0.isAlive || $0.pendingDefeat }
        let finished = encounters.filter { !$0.isAlive && !$0.pendingDefeat }
            .sorted { ($0.defeatedAtMs ?? $0.expiresAtMs) > ($1.defeatedAtMs ?? $1.expiresAtMs) }
            .prefix(Self.keepFinished)
        encounters = active + finished
    }
}

/// 원장 파일 저장소. 테스트는 메모리 구현을 쓴다.
protocol MonsterLedgerStorage: AnyObject {
    func load() -> MonsterLedgerState?
    func save(_ state: MonsterLedgerState)
}

final class MonsterLedgerFile: MonsterLedgerStorage {
    private let url: URL?

    init(fileName: String = "monster-encounters.v1.json") {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        url = dir?.appendingPathComponent(fileName)
    }

    func load() -> MonsterLedgerState? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MonsterLedgerState.self, from: data)
    }

    func save(_ state: MonsterLedgerState) {
        guard let url, let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

// MARK: - 기기 세션 장부

/// 키 → (받은 uid, 기록 시각). 40일이 지나면 지운다.
nonisolated struct DeviceSessionLedgerState: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let uid: String
        let atMs: Int64
    }
    var entries: [String: Entry] = [:]

    static let retentionMs: Int64 = 40 * 86_400_000

    /// 다른 계정이 이 키로 이미 받았으면 true(요청하지 않는다).
    func blocks(key: String, uid: String) -> Bool {
        guard let entry = entries[key] else { return false }
        return entry.uid != uid
    }

    mutating func record(key: String, uid: String, nowMs: Int64) {
        if entries[key] == nil { entries[key] = Entry(uid: uid, atMs: nowMs) }
    }

    mutating func purge(nowMs: Int64) {
        entries = entries.filter { nowMs - $0.value.atMs < Self.retentionMs }
    }
}

protocol DeviceSessionLedgerStorage: AnyObject {
    func load() -> DeviceSessionLedgerState
    func save(_ state: DeviceSessionLedgerState)
}

/// Keychain 저장(ThisDeviceOnly — 백업·기기 이전으로 옮겨 가지 않는다). 재설치해도 남는다.
final class DeviceSessionLedgerKeychain: DeviceSessionLedgerStorage {
    private let account = "monster.sessionLedger.v1"

    func load() -> DeviceSessionLedgerState {
        Keychain.json(DeviceSessionLedgerState.self, account: account) ?? DeviceSessionLedgerState()
    }

    func save(_ state: DeviceSessionLedgerState) {
        Keychain.setJSON(state, account: account)
    }
}
