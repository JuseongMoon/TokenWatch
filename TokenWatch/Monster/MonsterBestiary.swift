//
//  MonsterBestiary.swift
//  TokenWatch
//
//  프로필 도감에 줄 세울 몬스터(순수 함수). 공개된 종 중 이 앱이 그릴 수 있는 것과, 이미 잡은 종을 카탈로그 순서로 둔다.
//  공개 전 종(기간 이벤트 몬스터 등)은 잡기 전까지 실루엣도 보이지 않는다.
//

import Foundation

nonisolated struct BestiaryRow: Equatable, Sendable, Identifiable {
    let entry: MonsterCatalogEntry
    let kills: Int

    var id: String { entry.id }
    /// 한 번이라도 잡았다(모습·이름을 보여 준다).
    var discovered: Bool { kills > 0 }
}

enum MonsterBestiary {
    static func rows(config: MonsterConfig, kills: [String: Int], appVersion: String) -> [BestiaryRow] {
        config.catalog.compactMap { entry in
            let count = max(0, kills[entry.id] ?? 0)
            let drawable = entry.released
                && (entry.minAppVersion.map { AppVersionCompare.isAtLeast(appVersion, minimum: $0) } ?? true)
            return drawable || count > 0 ? BestiaryRow(entry: entry, kills: count) : nil
        }
    }
}
