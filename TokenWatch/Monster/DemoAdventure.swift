//
//  DemoAdventure.swift
//  TokenWatch
//
//  데모 모드의 표본 모험가(PLAYER 칸·계정 화면·모험가 순위·도감). 메모리 상수뿐이라 서버 호출·저장이 없다.
//  로그인한 실제 계정이 있어도 데모 중에는 이 표본만 보인다(데모 격리). 값은 Android와 같다.
//

import Foundation

nonisolated enum DemoAdventure {
    static let uid = "demo"
    static let methods: [AccountMethod] = [.apple]

    static func profile(_ lang: Lang) -> PlayerProfile {
        let nickname = lang == .ko ? "토큰사냥꾼" : "TokenHunter"
        return PlayerProfile(nickname: nickname, nicknameLower: nickname.lowercased(), tag: "0427",
                             nicknameChangedAtMs: 0, avatarID: "mage", termsAcceptedVersion: PlayerProfile.currentTermsVersion,
                             createdAtMs: 0, updatedAtMs: 0)
    }

    /// 도감 처치 수(고블린까지만 잡아 스켈레톤·오크·미믹은 실루엣으로 보인다). 점수 합 = 전체 탭 내 점수 780.
    static let kills: [String: Int] = ["slime": 48, "goblin": 6]

    /// 탭별 내 순위·점수·처치 수(이번 주 #4, 전체 #6).
    static func mine(_ scope: LeaderboardScope) -> (rank: Int, score: Int, common: Int, special: Int) {
        switch scope {
        case .week: return (4, 300, 15, 3)
        case .allTime: return (6, 780, 48, 6)
        }
    }

    /// 탭별 상위 10. 표본 11명(나 포함) 중 탭마다 한 명이 10위 밖으로 빠진다.
    /// 이름은 GitHub 사용자 이름 작명 방식을 따른 새 이름(한국어 화면은 한국 개발자식, 영어 화면은 해외식, 사용자 확정 2026-10-26).
    static func leaderboard(_ scope: LeaderboardScope, lang: Lang) -> [LeaderboardEntry] {
        let me = profile(lang)
        let people: [(ko: String, en: String, tag: String, avatar: String, week: Int, total: Int)] = [
            ("minseok94", "jmorrison", "3141", "rogue", 486, 905),
            ("hyeon-woo", "alexk-dev", "7720", "knight", 412, 1240),
            ("dkim0311", "0xmira", "0815", "hacker", 365, 1105),
            (me.nickname, me.nickname, me.tag, me.avatarID, mine(.week).score, mine(.allTime).score),
            ("ParkJiho", "tkellerman", "5562", "warrior", 251, 980),
            ("rkdwlsdn", "sam-ng", "2048", "cleric", 207, 840),
            ("seojun-lee", "priya_codes", "9013", "cat", 168, 610),
            ("chanhee7", "lucasferr", "4404", "robot", 132, 532),
            ("kongnamul", "nightowl42", "1206", "bard", 96, 455),
            ("devsoyeon", "dvorak-dan", "6378", "archer", 71, 390),
            ("yuna0827", "hkimura", "8291", "dragon", 40, 352),
        ]
        let rows = people.enumerated().map { index, p in
            let isMe = p.tag == me.tag
            let score = scope == .week ? p.week : p.total
            let special = isMe ? mine(scope).special : score / 200
            return LeaderboardEntry(
                uid: isMe ? uid : "demo-\(index)", nickname: lang == .ko ? p.ko : p.en, tag: p.tag,
                avatarID: p.avatar, score: score, reachedAtMs: Int64(index),
                commonKills: isMe ? mine(scope).common : max(0, (score - special * 75) / 10), specialKills: special)
        }
        return Array(rows.sorted { $0.score > $1.score }.prefix(MonsterAPIClient.leaderboardSize))
    }
}
