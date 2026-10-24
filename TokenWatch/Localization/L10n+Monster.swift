//
//  L10n+Monster.swift
//  TokenWatch
//
//  몬스터 사냥·모험가 순위(V2) 문구. 터미널 크롬(`RANKS`, `[ start ]`, `[ report ]` 등)은 번역하지 않고
//  자연어 문장만 둔다. Android는 이 원문을 그대로 옮겨 쓴다(양 플랫폼 같은 문구).
//

import Foundation

extension L10n {
    // MARK: 몬스터 이름(카탈로그 ID → 표시 이름, 모르는 ID는 ID 그대로)
    func monsterName(_ id: String) -> String {
        switch id {
        case "slime": return lang == .ko ? "슬라임" : "Slime"
        case "goblin": return lang == .ko ? "고블린" : "Goblin"
        case "skeleton": return lang == .ko ? "스켈레톤" : "Skeleton"
        case "orc": return lang == .ko ? "오크" : "Orc"
        case "mimic": return lang == .ko ? "미믹" : "Mimic"
        default: return id
        }
    }

    // MARK: 프로필 도감
    func bestiarySummary(found: Int, total: Int, kills: Int) -> String {
        lang == .ko ? "발견 \(found)/\(total) · 총 처치 \(kills)" : "Found \(found)/\(total) · \(kills) defeated"
    }
    var bestiaryHint: String {
        lang == .ko ? "몬스터를 처음 잡으면 모습과 이름이 드러나요. 이 계정의 처치 기록이에요."
                    : "Defeat a monster once to reveal it. These are this account's defeats."
    }
    var bestiaryLoading: String { lang == .ko ? "처치 기록을 불러오는 중…" : "Loading your defeats…" }
    var bestiaryFailed: String { lang == .ko ? "처치 기록을 불러오지 못했어요." : "Couldn't load your defeats." }
    var bestiaryUnknown: String { lang == .ko ? "아직 잡지 않은 몬스터" : "Not defeated yet" }
    func bestiaryA11y(name: String, kills: Int) -> String {
        lang == .ko ? "\(name), \(kills)마리 처치" : "\(name), \(kills) defeated"
    }

    // MARK: 게이지 전투(접근성)
    var monsterAttack: String { lang == .ko ? "공격" : "Attack" }
    func monsterA11yValue(name: String, hp: Int, maxHP: Int) -> String {
        lang == .ko ? "\(name), 남은 체력 \(hp)/\(maxHP)" : "\(name), \(hp) of \(maxHP) HP left"
    }
    func monsterA11yDefeated(name: String) -> String {
        lang == .ko ? "\(name) 처치됨" : "\(name) defeated"
    }

    // MARK: 길드 간판(상단 바)
    var guildBoardTitle: String { lang == .ko ? "모험가 순위" : "Adventurer Ranks" }
    func guildBoardGuestKills(_ n: Int) -> String {
        lang == .ko ? "이 기기에서 \(n)마리 처치" : "\(n) defeated on this device"
    }
    var guildBoardConsent: String { lang == .ko ? "몬스터 사냥을 시작하려면 동의가 필요해요" : "Agree to start the monster hunt" }

    // MARK: 리더보드
    func leaderboardTab(_ scope: LeaderboardScope) -> String {
        switch scope {
        case .week: return lang == .ko ? "이번 주" : "This week"
        case .allTime: return lang == .ko ? "전체" : "All time"
        }
    }
    func leaderboardIntro(_ scope: LeaderboardScope) -> String {
        switch scope {
        case .week:
            return lang == .ko ? "이번 주에 AI 사용량 게이지에서 잡은 몬스터 점수 순위예요. 매주 월요일 0시(한국 시간)에 새로 시작하고, 동점이면 먼저 도달한 사람이 위예요."
                               : "Points from monsters defeated on usage gauges this week. Starts over every Monday at 00:00 KST; ties go to whoever got there first."
        case .allTime:
            return lang == .ko ? "지금까지 AI 사용량 게이지에서 잡은 몬스터 점수 전체 순위예요. 동점이면 먼저 도달한 사람이 위예요."
                               : "All-time points from monsters defeated on usage gauges. Ties go to whoever got there first."
        }
    }
    var leaderboardLoading: String { lang == .ko ? "순위를 불러오는 중…" : "loading the ranks…" }
    var leaderboardFailed: String {
        lang == .ko ? "순위를 불러오지 못했어요. 잠시 뒤 다시 시도해 주세요."
                    : "Couldn't load the ranks. Try again in a moment."
    }
    var leaderboardEmpty: String { lang == .ko ? "아직 순위에 오른 모험가가 없어요." : "No adventurers ranked yet." }
    var leaderboardGuestHint: String {
        lang == .ko ? "TokenWatch 계정으로 로그인하고 몬스터 사냥에 동의하면 이 순위에 올라요. 로그인 전에 잡은 몬스터는 순위 없이 기록으로만 합쳐져요."
                    : "Sign in to a TokenWatch account and agree to the monster hunt to appear here. Monsters defeated before signing in are kept as unranked history."
    }
    func leaderboardMine(common: Int, special: Int) -> String {
        lang == .ko ? "슬라임 \(common) · 특수 \(special)" : "slimes \(common) · special \(special)"
    }
    var leaderboardNotListed: String { lang == .ko ? "아직 순위에 없어요" : "not ranked yet" }
    var leaderboardBlockedNote: String { lang == .ko ? "차단한 모험가는 이 기기에서 보이지 않아요." : "Blocked adventurers are hidden on this device." }

    // MARK: 신고·차단
    func reportTitle(_ nametag: String) -> String { lang == .ko ? "\(nametag) 신고" : "Report \(nametag)" }
    var reportIntro: String {
        lang == .ko ? "신고 사유를 고르세요. 여러 사람이 신고하면 순위에서 숨겨지고 운영자가 검토해요."
                    : "Pick a reason. When several people report someone, they're hidden from the ranks until an operator reviews it."
    }
    func reportReason(_ reason: MonsterAPIClient.ReportReason) -> String {
        switch reason {
        case .nickname: return lang == .ko ? "부적절한 닉네임" : "Inappropriate nickname"
        case .avatar: return lang == .ko ? "부적절한 아바타" : "Inappropriate avatar"
        case .cheating: return lang == .ko ? "부정행위 의심" : "Suspected cheating"
        case .other: return lang == .ko ? "기타" : "Other"
        }
    }
    var reportSent: String { lang == .ko ? "신고했어요. 검토할게요." : "Report sent. We'll take a look." }
    var reportFailed: String { lang == .ko ? "신고를 보내지 못했어요. 다시 시도해 주세요." : "Couldn't send the report. Try again." }
    var reportNeedsAccount: String { lang == .ko ? "신고는 로그인한 계정만 할 수 있어요." : "Sign in to report." }
    func blockTitle(_ nametag: String) -> String { lang == .ko ? "\(nametag) 차단" : "Block \(nametag)" }
    var blockMessage: String {
        lang == .ko ? "이 기기의 순위 목록에서 이 모험가를 숨겨요. 언제든 다시 보이게 할 수 있어요."
                    : "Hide this adventurer from the ranks on this device. You can undo it anytime."
    }

    // MARK: 동의(약관 v2)
    var consentTitle: String { lang == .ko ? "몬스터 사냥 시작하기" : "Start the monster hunt" }
    var consentIntro: String {
        lang == .ko ? "AI 사용량 게이지에 몬스터가 나타나고, 잡은 점수로 모험가 순위에 올라요. 몬스터 출현을 서버가 판정하기 때문에 아래 정보를 TokenWatch 서버로 보내요."
                    : "Monsters appear on your usage gauges, and the points you earn put you in the adventurer ranks. The server decides when monsters appear, so the app sends the following to the TokenWatch server."
    }
    var consentSent: [String] {
        lang == .ko ? ["AI 서비스 종류(예: Claude)와 사용량 창 이름(예: 주간)",
                       "그 창의 리셋 시각과 주기",
                       "몬스터 출현·처치 기록, 앱 버전과 플랫폼",
                       "연결한 AI 계정마다 앱이 만든 무작위 식별값(계정 정보는 아님)"]
                    : ["Which AI service (e.g. Claude) and the usage window name (e.g. weekly)",
                       "When that window resets and how long it is",
                       "Monsters spawned and defeated, the app version and platform",
                       "A random ID the app makes for each connected AI account (not the account itself)"]
    }
    var consentNotSent: String {
        lang == .ko ? "사용률 수치, AI 서비스 계정·이메일·토큰은 보내지 않아요. 닉네임 #번호, 아바타, 점수와 처치 수는 모험가 순위에서 다른 사람에게 보여요."
                    : "Usage percentages and your AI service accounts, emails, and tokens are never sent. Your nickname #number, avatar, score, and defeat counts are shown to others in the adventurer ranks."
    }
    var consentAgree: String {
        lang == .ko ? "변경된 이용약관과 개인정보 처리방침에 동의합니다."
                    : "I agree to the updated Terms of Service and Privacy Policy."
    }
    var consentFailed: String {
        lang == .ko ? "동의를 저장하지 못했어요. 네트워크를 확인하고 다시 시도해 주세요."
                    : "Couldn't save your agreement. Check your connection and try again."
    }
    var consentLater: String {
        lang == .ko ? "동의하지 않아도 사용량 기능은 그대로 쓸 수 있고, 몬스터는 이 기기에서만 순위 없이 기록돼요."
                    : "You can keep using every usage feature without agreeing; monsters are then kept only on this device, unranked."
    }
}
