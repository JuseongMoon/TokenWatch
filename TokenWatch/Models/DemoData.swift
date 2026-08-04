//
//  DemoData.swift
//  TokenWatch
//
//  로그인 없이 앱 전체 UI를 둘러볼 수 있는 데모 모드의 표본 데이터.
//  계정이 없는 사람(첫 실행 사용자·App Store 심사자)이 카드/게이지/상세/페이스 표기를
//  그대로 확인하는 용도다.
//
//  이 파일은 순수 값만 만든다 — 네트워크·Keychain·UserDefaults를 일절 건드리지 않는다.
//  (데모 상태를 실제 저장 데이터와 격리하는 책임은 `AgentStore`의 isDemo 가드가 진다.)
//

import Foundation

enum DemoData {
    /// 표본 계정 라벨. 실재하지 않는 주소를 쓴다(실제 계정으로 오인되지 않게).
    static let accountEmail = "demo@tokenwatch.app"

    /// 데모 에이전트의 고정 ID — 데모를 다시 열어도 같은 카드가 같은 순서로 선다.
    /// 실제 에이전트 UUID(무작위)와 겹칠 일이 없도록 눈에 띄는 상수 패턴을 쓴다.
    private static func id(_ n: Int) -> UUID {
        UUID(uuidString: "DE110000-0000-4000-8000-00000000000\(n)")!
    }

    /// 데모 카드 목록. 구독형 3종 + 충전형(API 크레딧) 1종으로 두 성격을 모두 보여준다.
    static func agents() -> [Agent] {
        [
            Agent(id: id(1), provider: .claude, accountLabel: accountEmail),
            Agent(id: id(2), provider: .codex, accountLabel: accountEmail),
            Agent(id: id(3), provider: .copilot, accountLabel: "demo-dev"),
            Agent(id: id(4), provider: .openrouter, accountLabel: "sk-or-…demo"),
        ]
    }

    /// 데모 스냅샷. 리셋 시각은 항상 `now` 기준 상대값이라 언제 실행해도 자연스럽다.
    /// 사용률은 시간 경과율과 살짝 어긋나게 잡아 "빠름/여유" 페이스 표기가 함께 보이게 했다.
    static func snapshots(now: Date = Date()) -> [UUID: AgentSnapshot] {
        let hour: TimeInterval = 3600
        let day: TimeInterval = 24 * hour

        // Claude — 세션은 시간보다 빠르게 소비 중(↑ ahead), 주간은 여유.
        // Opus 주간은 완전 소진(100%)으로 두어 게이지 위 슬라임이 행진하는 모습을 보여준다.
        let claude = AgentSnapshot(
            windows: [
                UsageWindow(label: "Current session", usedPercent: 68,
                            resetsAt: now.addingTimeInterval(1.8 * hour), kind: .session,
                            windowSeconds: WindowKind.session.defaultSeconds),
                UsageWindow(label: "Current week (all models)", usedPercent: 43,
                            resetsAt: now.addingTimeInterval(3.2 * day), kind: .weekly,
                            windowSeconds: WindowKind.weekly.defaultSeconds),
                UsageWindow(label: "Current week (Opus)", usedPercent: 100,
                            resetsAt: now.addingTimeInterval(3.2 * day), kind: .weekly,
                            windowSeconds: WindowKind.weekly.defaultSeconds),
            ],
            planLabel: "Max 20x", fetchedAt: now, error: nil)

        // Codex — 이제 막 시작한 세션 + 거의 다 쓴 주간(잔여 6% → 빨강 경고색).
        let codex = AgentSnapshot(
            windows: [
                UsageWindow(label: "Current session", usedPercent: 22,
                            resetsAt: now.addingTimeInterval(4.1 * hour), kind: .session,
                            windowSeconds: WindowKind.session.defaultSeconds),
                UsageWindow(label: "Current week", usedPercent: 94,
                            resetsAt: now.addingTimeInterval(4.6 * day), kind: .weekly,
                            windowSeconds: WindowKind.weekly.defaultSeconds),
            ],
            planLabel: "Plus", fetchedAt: now, error: nil)

        // Copilot — 월 단위 프리미엄 요청 한도(주기가 길어 weekly로 표기).
        let copilot = AgentSnapshot(
            windows: [
                UsageWindow(label: "Premium requests", usedPercent: 34,
                            resetsAt: now.addingTimeInterval(11 * day), kind: .weekly,
                            windowSeconds: 30 * day),
            ],
            planLabel: "Individual", fetchedAt: now, error: nil)

        // OpenRouter — 충전형 크레딧 게이지(채움 = 남은 잔액). 총액을 아는 경우라 추정 표기 없음.
        let creditTotal: Double = 50
        let creditLeft: Double = 37.1
        let openrouter = AgentSnapshot(
            windows: [
                UsageWindow(label: "Credits", usedPercent: (1 - creditLeft / creditTotal) * 100,
                            resetsAt: nil, kind: .weekly, windowSeconds: nil,
                            style: .creditGauge, valueText: creditText(creditLeft),
                            balanceRemaining: creditLeft, balanceTotal: creditTotal,
                            estimatedTotal: false),
            ],
            planLabel: nil, fetchedAt: now, error: nil)

        return [id(1): claude, id(2): codex, id(3): copilot, id(4): openrouter]
    }

    /// 데모 상태 배지 — 정상 두 개와 "주의" 하나를 섞어 신호등 표기를 함께 보여준다.
    static func serviceStatus() -> [AgentProvider: ServiceHealth] {
        [.claude: .operational, .codex: .operational, .copilot: .caution]
    }

    /// 상세 화면 ACCOUNT 카드용 표본 계정 정보(Keychain 조회를 대신한다).
    /// plan은 nil로 두어 상세 화면이 스냅샷의 planLabel을 쓰게 한다(실제 경로와 동일).
    static func accountInfo(for agent: Agent) -> AccountInfo {
        switch agent.provider {
        case .openrouter, .deepseek, .poe, .elevenlabs:
            // API 키 방식 — 이메일·만료·갱신 개념이 없다.
            return AccountInfo(email: nil, plan: nil, scopes: [], expiresAt: nil,
                               canRefresh: false, accountId: nil)
        case .claude, .codex, .copilot:
            return AccountInfo(email: accountEmail, plan: nil,
                               scopes: ["user:inference", "user:profile"],
                               expiresAt: Date().addingTimeInterval(21 * 24 * 3600),
                               canRefresh: true, accountId: "demo-account")
        }
    }

    // MARK: 데모 새로고침(틱)

    /// 새로고침 1회분을 진행시킨다 — 사용률을 조금씩 올리고, 리셋 시각이 지난 창은
    /// 다음 주기로 넘기며 0%부터 다시 시작한다(실제 앱의 리셋 거동을 그대로 재현).
    static func advanced(_ snapshots: [UUID: AgentSnapshot],
                         now: Date = Date()) -> [UUID: AgentSnapshot] {
        snapshots.mapValues { snapshot in
            AgentSnapshot(windows: snapshot.windows.map { tick($0, now: now) },
                          planLabel: snapshot.planLabel, fetchedAt: now, error: nil)
        }
    }

    private static func tick(_ window: UsageWindow, now: Date) -> UsageWindow {
        // 리셋 시각을 지났으면 다음 창으로 넘기고 사용률을 0부터 다시 센다.
        if let resetsAt = window.resetsAt, resetsAt <= now, let period = window.windowSeconds, period > 0 {
            var next = resetsAt
            while next <= now { next.addTimeInterval(period) }
            return replacing(window, usedPercent: 0, resetsAt: next)
        }

        switch window.style {
        case .gauge:
            // 이미 소진된 창(100%)은 그대로 둔다 — 슬라임이 계속 행진한다.
            // 아직 여유가 있는 창은 99%까지만 올린다: 데모를 오래 켜둬도 모든 게이지가
            // 100%로 수렴해 슬라임 천지가 되지 않고, "빨강 경고" 게이지가 계속 보인다.
            guard window.usedPercent < 99 else { return window }
            let next = min(99, window.usedPercent + Double.random(in: 0.2...1.1))
            return replacing(window, usedPercent: next, resetsAt: window.resetsAt)
        case .creditGauge:
            // 충전형은 잔액을 깎고 소비율·표시 문자열을 함께 다시 계산한다.
            guard let remaining = window.balanceRemaining,
                  let total = window.balanceTotal, total > 0 else { return window }
            let left = max(0, remaining - Double.random(in: 0.01...0.09))
            return UsageWindow(label: window.label, usedPercent: (1 - left / total) * 100,
                               resetsAt: window.resetsAt, kind: window.kind,
                               windowSeconds: window.windowSeconds, style: .creditGauge,
                               valueText: creditText(left), balanceRemaining: left,
                               balanceTotal: total, estimatedTotal: window.estimatedTotal)
        case .balance:
            return window
        }
    }

    /// 사용률·리셋 시각만 바꾼 복사본(나머지 필드는 그대로).
    private static func replacing(_ window: UsageWindow, usedPercent: Double,
                                  resetsAt: Date?) -> UsageWindow {
        UsageWindow(label: window.label, usedPercent: usedPercent, resetsAt: resetsAt,
                    kind: window.kind, windowSeconds: window.windowSeconds, style: window.style,
                    valueText: window.valueText, balanceRemaining: window.balanceRemaining,
                    balanceTotal: window.balanceTotal, estimatedTotal: window.estimatedTotal)
    }

    private static func creditText(_ amount: Double) -> String {
        String(format: "$%.2f left", amount)
    }
}
