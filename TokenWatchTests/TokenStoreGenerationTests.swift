//
//  TokenStoreGenerationTests.swift
//  TokenWatchTests
//
//  A1·A2 회귀: 늦게 끝난 이전 갱신이 새 로그인 세대의 토큰을 덮거나 지우지 못하고,
//  영구 갱신 실패 뒤에는 같은 죽은 refresh token으로 다시 요청하지 않는다.
//  가짜 refresher로 네트워크 완료 순서를 통제하고, 메모리 저장소로 Keychain을 대신한다.
//

import Testing
import Foundation
@testable import TokenWatch

@MainActor
struct TokenStoreGenerationTests {
    private typealias F = AuthFixtures

    private func makeStore(_ storage: MemoryCredentialStorage,
                           _ refresher: ScriptedRefresher) -> TokenStore {
        TokenStore(storage: storage, refresher: { _, tokens in try await refresher.refresh(tokens) })
    }

    // MARK: A1 — 재로그인과 늦은 갱신

    @Test func 갱신_도중_재로그인하면_늦은_성공이_새_토큰을_덮지_않는다() async throws {
        let storage = MemoryCredentialStorage(), refresher = ScriptedRefresher()
        let store = makeStore(storage, refresher)
        let id = UUID()
        storage.seed(F.oauth(access: "old-access", refresh: "old-refresh"), for: id)

        let caller = Task { try await store.validTokens(for: id, provider: .codex) }
        await eventually { await refresher.pendingCount == 1 }

        let relogin = F.oauth(access: "new-access", refresh: "new-refresh", expired: false)
        #expect(await store.replaceLogin(relogin, for: id))
        await refresher.completeNext(.success(F.oauth(access: "rotated-access", refresh: "rotated-refresh",
                                                     expired: false)))

        // 호출자에게 이전 세대 토큰을 돌려주지 않는다.
        await #expect(throws: CredentialSuperseded.self) { try await caller.value }
        #expect(storage.read(id)?.accessToken == "new-access")
        #expect(storage.read(id)?.refreshToken == "new-refresh")
    }

    @Test func 갱신_도중_재로그인하면_늦은_영구_실패가_새_refresh_token을_지우지_않는다() async throws {
        let storage = MemoryCredentialStorage(), refresher = ScriptedRefresher()
        let store = makeStore(storage, refresher)
        let id = UUID()
        storage.seed(F.oauth(access: "old-access", refresh: "old-refresh"), for: id)

        let caller = Task { try await store.forceRefresh(for: id, provider: .claude) }
        await eventually { await refresher.pendingCount == 1 }

        #expect(await store.replaceLogin(F.oauth(access: "new-access", refresh: "new-refresh", expired: false),
                                         for: id))
        await refresher.completeNext(.failure(OAuthError.refreshRevoked))

        await #expect(throws: CredentialSuperseded.self) { try await caller.value }
        #expect(storage.read(id)?.refreshToken == "new-refresh")
        #expect(storage.read(id)?.accessToken == "new-access")
    }

    @Test func 갱신_도중_카드를_지우면_늦은_결과가_자격증명을_되살리지_않는다() async throws {
        let storage = MemoryCredentialStorage(), refresher = ScriptedRefresher()
        let store = makeStore(storage, refresher)
        let id = UUID()
        storage.seed(F.oauth(access: "old-access", refresh: "old-refresh"), for: id)

        let caller = Task { try await store.validTokens(for: id, provider: .codex) }
        await eventually { await refresher.pendingCount == 1 }

        await store.delete(for: id)
        await refresher.completeNext(.success(F.oauth(access: "rotated", refresh: "rotated-r", expired: false)))

        _ = try? await caller.value
        #expect(storage.read(id) == nil)
    }

    @Test func 같은_세대의_동시_갱신은_한_번으로_합쳐진다() async throws {
        let storage = MemoryCredentialStorage(), refresher = ScriptedRefresher()
        let store = makeStore(storage, refresher)
        let id = UUID()
        storage.seed(F.oauth(access: "a", refresh: "r"), for: id)

        let first = Task { try await store.validTokens(for: id, provider: .codex) }
        await eventually { await refresher.pendingCount == 1 }
        let second = Task { try await store.forceRefresh(for: id, provider: .codex) }
        // 두 번째 호출이 합류할 시간을 준다 — 새 요청이 생기면 안 된다.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await refresher.callCount == 1)

        await refresher.completeNext(.success(F.oauth(access: "a2", refresh: "r2", expired: false)))
        #expect(try await first.value.accessToken == "a2")
        #expect(try await second.value.accessToken == "a2")
        #expect(await refresher.callCount == 1)
        #expect(storage.read(id)?.refreshToken == "r2")
    }

    @Test func 호출자가_취소돼도_로테이션된_토큰은_저장된다() async throws {
        let storage = MemoryCredentialStorage(), refresher = ScriptedRefresher()
        let store = makeStore(storage, refresher)
        let id = UUID()
        storage.seed(F.oauth(access: "a", refresh: "r"), for: id)

        let caller = Task { try await store.validTokens(for: id, provider: .claude) }
        await eventually { await refresher.pendingCount == 1 }
        caller.cancel()
        await refresher.completeNext(.success(F.oauth(access: "a2", refresh: "r2", expired: false)))

        _ = try? await caller.value
        await eventually { storage.read(id)?.refreshToken == "r2" }
        #expect(storage.read(id)?.refreshToken == "r2")
    }

    @Test func plan_갱신은_세대를_올리지_않고_이전_세대의_plan은_무시한다() async throws {
        let storage = MemoryCredentialStorage(), refresher = ScriptedRefresher()
        let store = makeStore(storage, refresher)
        let id = UUID()
        storage.seed(F.oauth(access: "a", refresh: "r", expired: false, plan: "free"), for: id)

        let before = await store.generation(for: id)
        await store.updatePlan("pro", for: id, generation: before)
        #expect(storage.read(id)?.plan == "pro")
        #expect(await store.generation(for: id) == before)   // 메타데이터 갱신은 새 로그인이 아니다

        #expect(await store.replaceLogin(F.oauth(access: "b", refresh: "rb", expired: false, plan: "team"),
                                         for: id))
        // 이전 세대 조회가 읽어 온 plan은 새 로그인에 반영하지 않는다.
        await store.updatePlan("free", for: id, generation: before)
        #expect(storage.read(id)?.plan == "team")
    }

    @Test func plan_갱신이_진행_중인_같은_세대_갱신을_무효화하지_않는다() async throws {
        let storage = MemoryCredentialStorage(), refresher = ScriptedRefresher()
        let store = makeStore(storage, refresher)
        let id = UUID()
        storage.seed(F.oauth(access: "a", refresh: "r"), for: id)

        let caller = Task { try await store.validTokens(for: id, provider: .codex) }
        await eventually { await refresher.pendingCount == 1 }
        await store.updatePlan("pro", for: id, generation: await store.generation(for: id))
        await refresher.completeNext(.success(F.oauth(access: "a2", refresh: "r2", expired: false)))

        #expect(try await caller.value.accessToken == "a2")
        #expect(storage.read(id)?.refreshToken == "r2")
    }

    @Test func 재로그인_저장이_실패하면_기존_세대의_갱신을_무효화하지_않는다() async throws {
        let storage = MemoryCredentialStorage(), refresher = ScriptedRefresher()
        let store = makeStore(storage, refresher)
        let id = UUID()
        storage.seed(F.oauth(access: "a", refresh: "r"), for: id)
        let before = await store.generation(for: id)

        let caller = Task { try await store.validTokens(for: id, provider: .codex) }
        await eventually { await refresher.pendingCount == 1 }

        storage.failWrites = true
        #expect(await store.replaceLogin(F.oauth(access: "b", refresh: "rb", expired: false), for: id) == false)
        #expect(await store.generation(for: id) == before)
        storage.failWrites = false

        await refresher.completeNext(.success(F.oauth(access: "a2", refresh: "r2", expired: false)))
        #expect(try await caller.value.accessToken == "a2")
        #expect(storage.read(id)?.refreshToken == "r2")
    }

    @Test func 이전_세대_갱신의_정리가_새_세대_갱신_합류를_끊지_않는다() async throws {
        let storage = MemoryCredentialStorage(), refresher = ScriptedRefresher()
        let store = makeStore(storage, refresher)
        let id = UUID()
        storage.seed(F.oauth(access: "a", refresh: "r"), for: id)

        let old = Task { try await store.validTokens(for: id, provider: .codex) }
        await eventually { await refresher.pendingCount == 1 }
        // 새 로그인(이미 만료된 토큰이라 곧바로 갱신이 필요한 경우)
        #expect(await store.replaceLogin(F.oauth(access: "b", refresh: "rb"), for: id))
        let fresh = Task { try await store.validTokens(for: id, provider: .codex) }
        await eventually { await refresher.pendingCount == 2 }

        // 이전 세대 요청을 먼저 끝낸다 — 정리 코드가 새 세대 항목을 지우면 아래 합류가 새 요청을 만든다.
        await refresher.completeNext(.success(F.oauth(access: "a2", refresh: "r2", expired: false)))
        _ = try? await old.value
        let joiner = Task { try await store.validTokens(for: id, provider: .codex) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await refresher.callCount == 2)

        await refresher.completeNext(.success(F.oauth(access: "b2", refresh: "rb2", expired: false)))
        #expect(try await fresh.value.accessToken == "b2")
        #expect(try await joiner.value.accessToken == "b2")
        #expect(storage.read(id)?.refreshToken == "rb2")
    }

    @Test func 세대가_바뀐_뒤_시작_세대를_지정한_조회는_거부된다() async throws {
        let storage = MemoryCredentialStorage(), refresher = ScriptedRefresher()
        let store = makeStore(storage, refresher)
        let id = UUID()
        storage.seed(F.oauth(access: "a", refresh: "r", expired: false), for: id)
        let gen = await store.generation(for: id)
        #expect(await store.replaceLogin(F.oauth(access: "b", refresh: "rb", expired: false), for: id))

        await #expect(throws: CredentialSuperseded.self) {
            try await store.validTokens(for: id, provider: .codex, generation: gen)
        }
        #expect(try await store.validTokens(for: id, provider: .codex,
                                            generation: await store.generation(for: id)).accessToken == "b")
    }

    // MARK: A2 — 영구 실패 뒤 재요청 금지 / 일시 실패는 보존

    @Test func 영구_갱신_실패_뒤_두_번째_조회는_갱신_요청을_보내지_않는다() async throws {
        let storage = MemoryCredentialStorage()
        let refresher = ScriptedRefresher(immediate: .failure(OAuthError.refreshRevoked))
        let store = makeStore(storage, refresher)
        let id = UUID()
        storage.seed(F.oauth(access: "a", refresh: "dead-refresh"), for: id)

        await #expect(throws: OAuthError.self) { try await store.validTokens(for: id, provider: .codex) }
        #expect(storage.read(id)?.refreshToken == nil)
        #expect(storage.read(id)?.accessToken == "a")   // 표시용 메타데이터는 남긴다

        await #expect(throws: OAuthError.self) { try await store.validTokens(for: id, provider: .codex) }
        #expect(await refresher.callCount == 1)
    }

    @Test(arguments: [
        OAuthError.refreshFailed("HTTP 500", code: "http_500"),
        OAuthError.refreshFailed("HTTP 429", code: "http_429"),
        OAuthError.refreshFailed("HTTP 400", code: "http_400"),
    ])
    func 일시_갱신_실패는_refresh_token을_보존한다(_ failure: OAuthError) async throws {
        let storage = MemoryCredentialStorage()
        let refresher = ScriptedRefresher(immediate: .failure(failure))
        let store = makeStore(storage, refresher)
        let id = UUID()
        storage.seed(F.oauth(access: "a", refresh: "live-refresh"), for: id)

        await #expect(throws: OAuthError.self) { try await store.validTokens(for: id, provider: .codex) }
        #expect(storage.read(id)?.refreshToken == "live-refresh")
        // 다음 조회에서 다시 시도한다(복구 가능할 수 있으므로).
        _ = try? await store.validTokens(for: id, provider: .codex)
        #expect(await refresher.callCount == 2)
    }

    @Test func 네트워크_오류도_refresh_token을_보존한다() async throws {
        let storage = MemoryCredentialStorage()
        let refresher = ScriptedRefresher(immediate: .failure(URLError(.notConnectedToInternet)))
        let store = makeStore(storage, refresher)
        let id = UUID()
        storage.seed(F.oauth(access: "a", refresh: "live-refresh"), for: id)

        await #expect(throws: URLError.self) { try await store.validTokens(for: id, provider: .codex) }
        #expect(storage.read(id)?.refreshToken == "live-refresh")
    }

    // MARK: 저장 형식 호환

    @Test func 계정_ID_필드가_없는_이전_저장본도_읽힌다() throws {
        let legacy = Data(#"{"accessToken":"a","refreshToken":"r","scopes":[],"accountEmail":"x@example.com"}"#.utf8)
        let decoded = try JSONDecoder().decode(OAuthTokens.self, from: legacy)
        #expect(decoded.stableUserID == nil)
        #expect(decoded.accessToken == "a")
        #expect(decoded.accountEmail == "x@example.com")

        var t = decoded
        t.stableUserID = "42"
        let round = try JSONDecoder().decode(OAuthTokens.self, from: JSONEncoder().encode(t))
        #expect(round.stableUserID == "42")
    }
}
