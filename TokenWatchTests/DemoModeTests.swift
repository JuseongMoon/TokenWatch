//
//  DemoModeTests.swift
//  TokenWatchTests
//
//  데모 모드(로그인 없이 둘러보기) 검증: 표본 데이터의 형태, 새로고침 틱의 거동,
//  그리고 데모가 실제 저장 데이터를 오염시키지 않는다는 격리 보장.
//

import Testing
import Foundation
@testable import TokenWatch

struct DemoModeTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: 표본 데이터

    /// 카드가 구독형·충전형을 모두 포함해 두 성격을 한 화면에서 보여준다.
    @Test func demoCoversBothUsageCategories() {
        let providers = DemoData.agents().map(\.provider)
        #expect(providers.contains { $0.usageCategory == .subscription })
        #expect(providers.contains { $0.usageCategory == .apiCredit })
    }

    /// 모든 데모 에이전트에 스냅샷이 있고, 에러 없이 창을 가진다.
    @Test func everyDemoAgentHasWindows() {
        let snapshots = DemoData.snapshots(now: now)
        for agent in DemoData.agents() {
            let snapshot = snapshots[agent.id]
            #expect(snapshot != nil)
            #expect(snapshot?.error == nil)
            #expect(snapshot?.windows.isEmpty == false)
        }
    }

    /// 리셋 시각은 항상 now 기준 미래 — 언제 데모를 열어도 "이미 지난 창"이 보이지 않는다.
    @Test func resetDatesAreInTheFuture() {
        for (_, snapshot) in DemoData.snapshots(now: now) {
            for window in snapshot.windows {
                if let resetsAt = window.resetsAt {
                    #expect(resetsAt > now)
                }
            }
        }
    }

    /// 게이지 창은 페이스 표기가 뜨도록 창 주기를 갖는다(마커·pace 계산의 전제).
    @Test func gaugeWindowsCarryWindowSeconds() {
        for (_, snapshot) in DemoData.snapshots(now: now) {
            for window in snapshot.windows where window.style == .gauge {
                #expect(window.windowSeconds != nil)
                #expect(window.resetsAt != nil)
            }
        }
    }

    // MARK: 새로고침 틱

    /// 틱은 사용률을 올리고 조회 시각을 갱신한다.
    @Test func tickAdvancesUsage() {
        let before = DemoData.snapshots(now: now)
        let after = DemoData.advanced(before, now: now.addingTimeInterval(60))

        var moved = false
        for (id, snapshot) in after {
            #expect(snapshot.fetchedAt == now.addingTimeInterval(60))
            guard let old = before[id] else { continue }
            for (i, window) in snapshot.windows.enumerated() where window.style == .gauge {
                if window.usedPercent > old.windows[i].usedPercent { moved = true }
            }
        }
        #expect(moved)
    }

    /// 사용률은 100%를 넘지 않는다(틱을 많이 돌려도 게이지가 깨지지 않는다).
    @Test func tickClampsAtHundred() {
        var snapshots = DemoData.snapshots(now: now)
        for i in 1...400 {
            snapshots = DemoData.advanced(snapshots, now: now.addingTimeInterval(Double(i)))
        }
        for (_, snapshot) in snapshots {
            for window in snapshot.windows {
                #expect(window.usedPercent <= 100)
                #expect(window.usedPercent >= 0)
            }
        }
    }

    /// 리셋 시각을 지나면 창이 다음 주기로 넘어가고 사용률이 0부터 다시 시작한다.
    @Test func tickRollsOverPastReset() {
        let before = DemoData.snapshots(now: now)
        // 가장 이른 리셋(세션 1.8시간)을 확실히 지나도록 6시간 뒤로 이동.
        let later = now.addingTimeInterval(6 * 3600)
        let after = DemoData.advanced(before, now: later)

        var rolled = false
        for (_, snapshot) in after {
            for window in snapshot.windows {
                guard let resetsAt = window.resetsAt else { continue }
                // 넘긴 창이든 아니든, 리셋 시각은 항상 현재보다 미래여야 한다.
                #expect(resetsAt > later)
                if window.usedPercent == 0 { rolled = true }
            }
        }
        #expect(rolled)
    }

    /// 충전형 창은 잔액이 줄면 소비율이 그만큼 오르고, 표시 문자열도 함께 따라간다.
    @Test func creditWindowStaysConsistent() {
        let before = DemoData.snapshots(now: now)
        let after = DemoData.advanced(before, now: now.addingTimeInterval(60))

        for (_, snapshot) in after {
            for window in snapshot.windows where window.style == .creditGauge {
                guard let remaining = window.balanceRemaining,
                      let total = window.balanceTotal, total > 0 else {
                    Issue.record("충전형 창에 잔액/총액이 없음")
                    continue
                }
                let expected = (1 - remaining / total) * 100
                #expect(abs(window.usedPercent - expected) < 0.001)
                #expect(window.valueText?.contains(String(format: "%.2f", remaining)) == true)
            }
        }
    }

    // MARK: 격리 — 데모가 실제 상태를 건드리지 않는다

    /// 데모에 들어갔다 나오면 원래 목록·스냅샷이 그대로 돌아온다.
    @MainActor
    @Test func demoRestoresPreviousState() {
        let store = AgentStore()
        let before = store.agents.map(\.id)

        store.enterDemo()
        #expect(store.isDemo)
        #expect(store.agents.map(\.id) == DemoData.agents().map(\.id))

        store.exitDemo()
        #expect(!store.isDemo)
        #expect(store.agents.map(\.id) == before)
    }

    /// 데모 중 카드를 지워도 실제 목록에는 영향이 없다(나가면 그대로 복원).
    @MainActor
    @Test func removingDemoCardDoesNotTouchRealList() {
        let store = AgentStore()
        let before = store.agents.map(\.id)

        store.enterDemo()
        if let first = store.agents.first { store.remove(first) }
        #expect(store.agents.count == DemoData.agents().count - 1)

        store.exitDemo()
        #expect(store.agents.map(\.id) == before)
    }

    /// 데모 중에는 로그인 추가가 막힌다(표본 목록에 실계정이 섞이지 않게).
    @MainActor
    @Test func addAgentIsBlockedInDemo() async {
        let store = AgentStore()
        store.enterDemo()
        let tokens = OAuthTokens(accessToken: "demo-should-not-save", refreshToken: nil,
                                 expiresAt: nil, scopes: [], accountEmail: nil, plan: nil)
        let ok = await store.addAgent(provider: .claude, tokens: tokens)
        #expect(!ok)
        #expect(store.agents.map(\.id) == DemoData.agents().map(\.id))
        store.exitDemo()
    }
}
