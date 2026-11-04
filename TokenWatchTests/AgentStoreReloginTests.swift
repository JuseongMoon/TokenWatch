//
//  AgentStoreReloginTests.swift
//  TokenWatchTests
//
//  A1·A4 상위 계층 회귀: 실제 `AgentStore.addAgent`·`refresh` 경로를 지나며
//  - 재로그인 직후(20초 스로틀 안이어도) 새 자격증명으로 실제 조회가 한 번 일어나고
//  - 이전 자격증명으로 진행 중이던 조회의 결과(오류 포함)는 화면에 반영되지 않는다.
//  A3: Copilot 같은 계정 재로그인은 GitHub 사용자 ID로만 기존 카드를 찾는다.
//
//  UserDefaults는 격리된 suite, 토큰은 메모리 저장소, 조회는 완료 순서를 통제하는 가짜를 쓴다.
//  OpenRouter는 상태 페이지 조회가 없어 네트워크 호출이 생기지 않는다.
//

import Testing
import Foundation
@testable import TokenWatch

@MainActor
struct AgentStoreReloginTests {
    private typealias F = AuthFixtures

    private struct Harness {
        let store: AgentStore
        let storage: MemoryCredentialStorage
        let tokenStore: TokenStore
        let fetcher: ScriptedFetcher
        let agent: Agent
    }

    /// 이메일 라벨을 가진 OpenRouter 카드 하나가 이미 있는 상태.
    private func makeHarness(label: String = "user@example.com") -> Harness {
        let defaults = F.isolatedDefaults()
        let agent = Agent(provider: .openrouter, accountLabel: label)
        F.seedAgents([agent], into: defaults)
        let storage = MemoryCredentialStorage()
        storage.seed(.apiKey("old-key", email: label), for: agent.id)
        let tokenStore = TokenStore(storage: storage, refresher: { _, _ in throw OAuthError.notAuthenticated })
        let fetcher = ScriptedFetcher()
        let store = AgentStore(defaults: defaults, tokenStore: tokenStore,
                               fetchSnapshot: { _, _, _ in await fetcher.fetch() },
                               copilotIdentity: { _ in nil })
        return Harness(store: store, storage: storage, tokenStore: tokenStore, fetcher: fetcher, agent: agent)
    }

    // MARK: A4 — 재로그인 직후 실제 조회

    @Test func 인증_오류_직후_20초_안에_재로그인해도_새_자격증명으로_다시_조회한다() async throws {
        let h = makeHarness()
        let first = Task { await h.store.refresh(h.agent) }
        await eventually { h.fetcher.pendingCount == 1 }
        h.fetcher.completeNext(F.errorSnapshot())
        await first.value
        #expect(h.store.snapshots[h.agent.id]?.error != nil)

        let add = Task { await h.store.addAgent(provider: .openrouter, tokens: .apiKey("new-key", email: "user@example.com")) }
        await eventually { h.fetcher.pendingCount == 1 }
        #expect(h.fetcher.callCount == 2)   // 스로틀에 막히지 않았다
        h.fetcher.completeNext(F.okSnapshot())
        #expect(await add.value)

        #expect(h.store.agents.count == 1)   // 같은 카드
        #expect(h.store.snapshots[h.agent.id]?.error == nil)
        #expect(h.storage.read(h.agent.id)?.accessToken == "new-key")
    }

    @Test func 이전_조회_진행_중에_재로그인하면_이전_결과를_버리고_새로_조회한다() async throws {
        let h = makeHarness()
        let inFlight = Task { await h.store.refresh(h.agent) }
        await eventually { h.fetcher.pendingCount == 1 }

        // 진행 중인 조회가 있어 addAgent의 조회는 곧바로 돌아온다(시트는 닫힌다).
        #expect(await h.store.addAgent(provider: .openrouter,
                                       tokens: .apiKey("new-key", email: "user@example.com")))
        #expect(h.fetcher.callCount == 1)

        // 이전 자격증명의 늦은 오류 — 화면에 반영하지 않고 새 자격증명으로 다시 조회해야 한다.
        h.fetcher.completeNext(F.errorSnapshot("stale error from old key"))
        await eventually { h.fetcher.pendingCount == 1 }
        #expect(h.fetcher.callCount == 2)
        #expect(h.store.snapshots[h.agent.id]?.error == nil)

        h.fetcher.completeNext(F.okSnapshot("Fresh"))
        await inFlight.value
        #expect(h.store.snapshots[h.agent.id]?.error == nil)
        #expect(h.store.snapshots[h.agent.id]?.windows.first?.label == "Fresh")
    }

    @Test func 재로그인_뒤의_일반_자동_조회는_여전히_스로틀을_따른다() async throws {
        let h = makeHarness()
        let add = Task { await h.store.addAgent(provider: .openrouter, tokens: .apiKey("new-key", email: "user@example.com")) }
        await eventually { h.fetcher.pendingCount == 1 }
        h.fetcher.completeNext(F.okSnapshot())
        _ = await add.value

        // 20초 안의 일반(자동) 조회는 버스트 스로틀에 흡수된다 — 재로그인 우회가 전체 제한을 없애지 않는다.
        await h.store.refresh(h.agent)
        #expect(h.fetcher.callCount == 1)

        // 수동 새로고침은 기존처럼 항상 실행된다.
        let manual = Task { await h.store.refresh(h.agent, manual: true) }
        await eventually { h.fetcher.pendingCount == 1 }
        #expect(h.fetcher.callCount == 2)
        h.fetcher.completeNext(F.okSnapshot())
        await manual.value
    }

    @Test func 조회_도중_카드를_지우면_늦은_결과가_스냅샷을_되살리지_않는다() async throws {
        let h = makeHarness()
        let inFlight = Task { await h.store.refresh(h.agent) }
        await eventually { h.fetcher.pendingCount == 1 }

        h.store.remove(h.agent)
        h.fetcher.completeNext(F.okSnapshot())
        await inFlight.value

        #expect(h.store.snapshots[h.agent.id] == nil)
        #expect(h.fetcher.callCount == 1)   // 지운 카드는 다시 조회하지 않는다
        await eventually { h.storage.read(h.agent.id) == nil }
        #expect(h.storage.read(h.agent.id) == nil)
    }

    @Test func 재로그인은_토큰_저장_세대를_올린다() async throws {
        let h = makeHarness()
        let before = await h.tokenStore.generation(for: h.agent.id)
        let add = Task { await h.store.addAgent(provider: .openrouter, tokens: .apiKey("new-key", email: "user@example.com")) }
        await eventually { h.fetcher.pendingCount == 1 }
        h.fetcher.completeNext(F.okSnapshot())
        _ = await add.value
        #expect(await h.tokenStore.generation(for: h.agent.id) == before + 1)
    }

    @Test func 재로그인_저장에_실패하면_카드와_토큰을_그대로_둔다() async throws {
        let h = makeHarness()
        h.storage.failWrites = true
        #expect(await h.store.addAgent(provider: .openrouter,
                                       tokens: .apiKey("new-key", email: "user@example.com")) == false)
        #expect(h.store.agents.map(\.id) == [h.agent.id])
        #expect(h.storage.read(h.agent.id)?.accessToken == "old-key")
        #expect(h.fetcher.callCount == 0)
    }

    // MARK: A3 — Copilot 계정 식별

    private struct CopilotHarness {
        let store: AgentStore
        let storage: MemoryCredentialStorage
        let fetcher: ScriptedFetcher
    }

    /// 주어진 Copilot 카드·저장 토큰으로 시작한다. `resolve`는 레거시 토큰 → GitHub ID(가짜).
    private func makeCopilot(_ seeded: [(Agent, OAuthTokens)],
                             resolve: @escaping @Sendable (String) async -> String?) -> CopilotHarness {
        let defaults = F.isolatedDefaults()
        F.seedAgents(seeded.map(\.0), into: defaults)
        let storage = MemoryCredentialStorage()
        for (agent, tokens) in seeded { storage.seed(tokens, for: agent.id) }
        let fetcher = ScriptedFetcher()
        let store = AgentStore(defaults: defaults,
                               tokenStore: TokenStore(storage: storage, refresher: { _, _ in throw OAuthError.notAuthenticated }),
                               fetchSnapshot: { _, _, _ in await fetcher.fetch() },
                               copilotIdentity: resolve)
        return CopilotHarness(store: store, storage: storage, fetcher: fetcher)
    }

    private func copilotLogin(access: String, userID: String?) -> OAuthTokens {
        var t = OAuthTokens(accessToken: access, refreshToken: nil, expiresAt: nil, scopes: [],
                            accountEmail: nil, plan: nil)
        t.stableUserID = userID
        return t
    }

    /// addAgent를 끝까지 진행한다(조회가 생기면 정상 스냅샷으로 끝낸다).
    private func add(_ h: CopilotHarness, _ tokens: OAuthTokens) async -> Bool {
        let task = Task { await h.store.addAgent(provider: .copilot, tokens: tokens) }
        await eventually { h.fetcher.pendingCount == 1 }
        h.fetcher.completeNext(F.okSnapshot("Premium"))
        return await task.value
    }

    @Test func 같은_GitHub_ID로_다시_로그인하면_기존_카드의_토큰만_교체한다() async throws {
        let existing = Agent(provider: .copilot, accountLabel: "Copilot Pro")
        let h = makeCopilot([(existing, copilotLogin(access: "old", userID: "42"))], resolve: { _ in nil })

        #expect(await add(h, copilotLogin(access: "new", userID: "42")))
        #expect(h.store.agents.map(\.id) == [existing.id])            // 카드 UUID 유지
        #expect(h.store.agents.first?.accountLabel == "Copilot Pro")   // 표시값·설정 유지
        #expect(h.storage.read(existing.id)?.accessToken == "new")
    }

    @Test func 다른_GitHub_ID는_별도_카드가_된다() async throws {
        let existing = Agent(provider: .copilot, accountLabel: "Copilot Pro")
        let h = makeCopilot([(existing, copilotLogin(access: "old", userID: "42"))], resolve: { _ in nil })

        #expect(await add(h, copilotLogin(access: "other", userID: "43")))
        #expect(h.store.agents.count == 2)
        #expect(h.storage.read(existing.id)?.accessToken == "old")
    }

    @Test func 표시명이_같아도_ID가_다르면_합치지_않고_ID가_같으면_표시명이_달라도_합친다() async throws {
        let a = Agent(provider: .copilot, accountLabel: "Copilot Business")
        let h = makeCopilot([(a, copilotLogin(access: "old", userID: "7"))], resolve: { _ in nil })

        // 새 로그인의 이메일·플랜이 비어 있어도(비공개) ID만으로 판별한다.
        #expect(await add(h, copilotLogin(access: "new", userID: "7")))
        #expect(h.store.agents.count == 1)
    }

    @Test func ID가_없는_레거시_카드는_저장_토큰으로_확인될_때만_합치고_ID를_채운다() async throws {
        let legacy = Agent(provider: .copilot, accountLabel: "Copilot Pro")
        let h = makeCopilot([(legacy, copilotLogin(access: "legacy-token", userID: nil))],
                            resolve: { token in token == "legacy-token" ? "42" : nil })

        #expect(await add(h, copilotLogin(access: "new", userID: "42")))
        #expect(h.store.agents.map(\.id) == [legacy.id])
        #expect(h.storage.read(legacy.id)?.accessToken == "new")
        #expect(h.storage.read(legacy.id)?.stableUserID == "42")
    }

    @Test func 확인할_수_없는_레거시_카드는_추측으로_합치거나_지우지_않는다() async throws {
        let legacy = Agent(provider: .copilot, accountLabel: "Copilot Pro")
        let h = makeCopilot([(legacy, copilotLogin(access: "dead-token", userID: nil))],
                            resolve: { _ in nil })   // 토큰이 죽어 식별 불가

        #expect(await add(h, copilotLogin(access: "new", userID: "42")))
        #expect(h.store.agents.count == 2)
        #expect(h.storage.read(legacy.id)?.accessToken == "dead-token")   // 기존 자격증명 보존
        #expect(h.storage.read(legacy.id)?.stableUserID == nil)
    }

    @Test func 레거시_카드의_ID가_다르면_합치지_않되_ID는_채운다() async throws {
        let legacy = Agent(provider: .copilot, accountLabel: "Copilot Pro")
        let h = makeCopilot([(legacy, copilotLogin(access: "legacy-token", userID: nil))],
                            resolve: { _ in "99" })

        #expect(await add(h, copilotLogin(access: "new", userID: "42")))
        #expect(h.store.agents.count == 2)
        #expect(h.storage.read(legacy.id)?.stableUserID == "99")
        #expect(h.storage.read(legacy.id)?.accessToken == "legacy-token")
    }

    @Test func ID_없는_Copilot_로그인은_기존_카드와_합치지_않는다() async throws {
        let existing = Agent(provider: .copilot, accountLabel: nil)
        let h = makeCopilot([(existing, copilotLogin(access: "old", userID: "42"))], resolve: { _ in "42" })

        #expect(await add(h, copilotLogin(access: "new", userID: nil)))
        #expect(h.store.agents.count == 2)
        #expect(h.storage.read(existing.id)?.accessToken == "old")
    }

    @Test func GitHub_user_응답에서_숫자_ID만_받는다() {
        #expect(CopilotDeviceFlow.parseUserID(Data(#"{"id": 583231, "login": "octocat"}"#.utf8)) == "583231")
        #expect(CopilotDeviceFlow.parseUserID(Data(#"{"login": "octocat"}"#.utf8)) == nil)
        #expect(CopilotDeviceFlow.parseUserID(Data(#"{"id": "583231"}"#.utf8)) == nil)
        #expect(CopilotDeviceFlow.parseUserID(Data(#"{"id": true}"#.utf8)) == nil)
        #expect(CopilotDeviceFlow.parseUserID(Data(#"{"id": 0}"#.utf8)) == nil)
        #expect(CopilotDeviceFlow.parseUserID(Data(#"{"id": 1.5}"#.utf8)) == nil)
        #expect(CopilotDeviceFlow.parseUserID(Data("not json".utf8)) == nil)
    }
}
