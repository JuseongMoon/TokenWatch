//
//  TokenStoreUnsavedTests.swift
//  TokenWatchTests
//
//  회전 토큰 저장 실패 회귀: 두 번 다 저장하지 못한 회전 토큰은 버리지 않고 메모리에 들고 있다가
//  저장본보다 먼저 쓰고, 접근마다 다시 저장해 성공하면 지운다. 메모리에만 있는 동안에는 갱신하지 않는다.
//  새 로그인·삭제(세대 변경) 때는 지운다. 메모리 저장소의 `failWrites`로 Keychain 쓰기 실패를 흉내 낸다.
//

import Testing
import Foundation
@testable import TokenWatch

@MainActor
struct TokenStoreUnsavedTests {
    private typealias F = AuthFixtures

    private func makeStore(_ storage: MemoryCredentialStorage,
                           _ refresher: ScriptedRefresher) -> TokenStore {
        TokenStore(storage: storage, refresher: { _, tokens in try await refresher.refresh(tokens) })
    }

    /// 갱신 결과로 돌려줄 회전 토큰.
    private func rotated(expired: Bool = false) -> OAuthTokens {
        F.oauth(access: "rotated-access", refresh: "rotated-refresh", expired: expired)
    }

    /// 만료된 토큰을 저장해 두고, 저장이 실패하는 동안 갱신해 회전 토큰을 메모리에만 남긴다.
    /// 끝난 뒤에도 `failWrites`는 켜져 있다.
    private func holdRotated(_ store: TokenStore, _ storage: MemoryCredentialStorage,
                             id: UUID) async throws -> OAuthTokens {
        storage.seed(F.oauth(access: "old-access", refresh: "old-refresh"), for: id)
        storage.failWrites = true
        return try await store.validTokens(for: id, provider: .codex)
    }

    // MARK: 저장 실패 → 메모리 토큰 제공

    @Test func 회전_토큰을_저장하지_못해도_호출자는_새_토큰을_받고_다음_접근도_그_토큰을_쓴다() async throws {
        let storage = MemoryCredentialStorage()
        let refresher = ScriptedRefresher(immediate: .success(rotated()))
        let store = makeStore(storage, refresher)
        let id = UUID()

        #expect(try await holdRotated(store, storage, id: id).accessToken == "rotated-access")
        // 기존 저장본은 지워지지 않고 그대로 남는다.
        #expect(storage.read(id)?.refreshToken == "old-refresh")

        // 저장본(이미 쓴 refresh token)보다 메모리의 회전 토큰을 먼저 쓴다 — 갱신 요청을 다시 보내지 않는다.
        #expect(try await store.validTokens(for: id, provider: .codex).accessToken == "rotated-access")
        #expect(await store.tokens(for: id)?.refreshToken == "rotated-refresh")
        #expect(await refresher.callCount == 1)
    }

    @Test func 다음_접근에서_다시_저장되면_메모리_토큰을_지운다() async throws {
        let storage = MemoryCredentialStorage()
        let refresher = ScriptedRefresher(immediate: .success(rotated()))
        let store = makeStore(storage, refresher)
        let id = UUID()
        _ = try await holdRotated(store, storage, id: id)

        storage.failWrites = false
        #expect(try await store.validTokens(for: id, provider: .codex).accessToken == "rotated-access")
        #expect(storage.read(id)?.accessToken == "rotated-access")
        #expect(storage.read(id)?.refreshToken == "rotated-refresh")

        // 메모리 값이 지워졌다 — 이제는 저장본을 읽는다.
        storage.seed(F.oauth(access: "stored-access", refresh: "stored-refresh", expired: false), for: id)
        #expect(await store.tokens(for: id)?.accessToken == "stored-access")
        #expect(await refresher.callCount == 1)
    }

    @Test func 메모리에만_있는_토큰이_만료되면_갱신하지_않고_저장될_때까지_실패한다() async throws {
        let storage = MemoryCredentialStorage()
        let refresher = ScriptedRefresher(immediate: .success(rotated(expired: true)))
        let store = makeStore(storage, refresher)
        let id = UUID()
        _ = try await holdRotated(store, storage, id: id)

        await #expect(throws: CredentialUnavailable.self) { try await store.validTokens(for: id, provider: .codex) }
        await #expect(throws: CredentialUnavailable.self) { try await store.forceRefresh(for: id, provider: .codex) }
        #expect(await refresher.callCount == 1)
        // 로그인이 풀린 것이 아니다 — 메모리 토큰은 그대로 있다.
        #expect(await store.tokens(for: id)?.refreshToken == "rotated-refresh")

        // 저장되면 이미 쓴 옛 refresh token이 아니라 회전 토큰으로 갱신한다.
        storage.failWrites = false
        _ = try await store.validTokens(for: id, provider: .codex)
        #expect(await refresher.callCount == 2)
        #expect(await refresher.received.last?.refreshToken == "rotated-refresh")
    }

    @Test func plan_갱신은_메모리_토큰에도_반영되고_저장될_때_함께_남는다() async throws {
        let storage = MemoryCredentialStorage()
        let refresher = ScriptedRefresher(immediate: .success(rotated()))
        let store = makeStore(storage, refresher)
        let id = UUID()
        _ = try await holdRotated(store, storage, id: id)

        await store.updatePlan("pro", for: id, generation: await store.generation(for: id))
        #expect(await store.tokens(for: id)?.plan == "pro")
        #expect(await store.tokens(for: id)?.refreshToken == "rotated-refresh")

        storage.failWrites = false
        _ = await store.tokens(for: id)
        #expect(storage.read(id)?.plan == "pro")
        #expect(storage.read(id)?.refreshToken == "rotated-refresh")
    }

    // MARK: 세대 변경 때 정리

    @Test func 새_로그인은_저장_못_한_회전_토큰을_버린다() async throws {
        let storage = MemoryCredentialStorage()
        let refresher = ScriptedRefresher(immediate: .success(rotated()))
        let store = makeStore(storage, refresher)
        let id = UUID()
        _ = try await holdRotated(store, storage, id: id)

        storage.failWrites = false
        #expect(await store.replaceLogin(F.oauth(access: "new-access", refresh: "new-refresh", expired: false),
                                         for: id))
        #expect(await store.tokens(for: id)?.accessToken == "new-access")
        #expect(try await store.validTokens(for: id, provider: .codex).accessToken == "new-access")
        // 이전 세대의 메모리 토큰이 새 로그인을 덮어쓰지 않았다.
        #expect(storage.read(id)?.refreshToken == "new-refresh")
    }

    @Test func 재로그인_저장이_실패하면_메모리_토큰을_그대로_쓴다() async throws {
        let storage = MemoryCredentialStorage()
        let refresher = ScriptedRefresher(immediate: .success(rotated()))
        let store = makeStore(storage, refresher)
        let id = UUID()
        _ = try await holdRotated(store, storage, id: id)
        let before = await store.generation(for: id)

        #expect(await store.replaceLogin(F.oauth(access: "new-access", refresh: "new-refresh", expired: false),
                                         for: id) == false)
        #expect(await store.generation(for: id) == before)
        #expect(await store.tokens(for: id)?.refreshToken == "rotated-refresh")
    }

    @Test func 삭제는_저장_못_한_회전_토큰을_버리고_되살리지_않는다() async throws {
        let storage = MemoryCredentialStorage()
        let refresher = ScriptedRefresher(immediate: .success(rotated()))
        let store = makeStore(storage, refresher)
        let id = UUID()
        _ = try await holdRotated(store, storage, id: id)

        storage.failWrites = false
        await store.delete(for: id)
        #expect(await store.tokens(for: id) == nil)
        // 메모리 토큰이 다시 저장돼 지운 카드의 자격증명이 되살아나지 않는다.
        #expect(storage.read(id) == nil)
        await #expect(throws: OAuthError.self) { try await store.validTokens(for: id, provider: .codex) }
    }
}
