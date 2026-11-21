//
//  KeychainWriteTests.swift
//  TokenWatchTests
//
//  Keychain 쓰기 순서 검증: 기존 항목은 값만 바꾸고 항목이 없을 때만 새로 만든다.
//  지우기 단계가 없어 어느 단계에서 실패해도 기존 항목이 남는다. 실제 Keychain 대신 상태 코드를 흉내 낸다.
//

import Testing
import Foundation
import Security
@testable import TokenWatch

struct KeychainWriteTests {

    /// 정해 둔 상태 코드로 쓰기 순서를 돌리고, 성공 여부와 호출 순서를 돌려준다.
    /// 준비한 코드보다 많이 부르면 `errSecParam`(실패)을 돌려주고 호출 순서에 그대로 남는다.
    private func run(updates: [OSStatus], adds: [OSStatus] = []) -> (ok: Bool, calls: [String]) {
        var updates = updates, adds = adds, calls: [String] = []
        let ok = Keychain.write(
            update: {
                calls.append("update")
                return updates.isEmpty ? errSecParam : updates.removeFirst()
            },
            add: {
                calls.append("add")
                return adds.isEmpty ? errSecParam : adds.removeFirst()
            })
        return (ok, calls)
    }

    // MARK: 상태 코드 → 다음 단계

    @Test func 값_바꾸기_결과로_다음_단계를_정한다() {
        #expect(Keychain.step(afterUpdate: errSecSuccess) == .succeeded)
        #expect(Keychain.step(afterUpdate: errSecItemNotFound) == .add)
        #expect(Keychain.step(afterUpdate: errSecInteractionNotAllowed) == .failed)
        #expect(Keychain.step(afterUpdate: errSecDiskFull) == .failed)
        #expect(Keychain.step(afterUpdate: errSecParam) == .failed)
    }

    @Test func 추가_결과로_다음_단계를_정한다() {
        #expect(Keychain.step(afterAdd: errSecSuccess) == .succeeded)
        #expect(Keychain.step(afterAdd: errSecDuplicateItem) == .update)
        #expect(Keychain.step(afterAdd: errSecInteractionNotAllowed) == .failed)
        #expect(Keychain.step(afterAdd: errSecDiskFull) == .failed)
        #expect(Keychain.step(afterAdd: errSecParam) == .failed)
    }

    // MARK: 쓰기 순서

    @Test func 기존_항목은_값만_바꾸고_새로_만들지_않는다() {
        let r = run(updates: [errSecSuccess])
        #expect(r.ok)
        #expect(r.calls == ["update"])
    }

    @Test func 항목이_없을_때만_새로_만든다() {
        let r = run(updates: [errSecItemNotFound], adds: [errSecSuccess])
        #expect(r.ok)
        #expect(r.calls == ["update", "add"])
    }

    @Test(arguments: [errSecInteractionNotAllowed, errSecDiskFull, errSecParam])
    func 값_바꾸기가_실패하면_새로_만들지_않고_실패를_알린다(_ status: OSStatus) {
        // 잠금 중·저장 공간 부족 등 — 기존 항목에는 손대지 않는다(지우는 단계 자체가 없다).
        let r = run(updates: [status])
        #expect(!r.ok)
        #expect(r.calls == ["update"])
    }

    @Test func 새로_만들기가_실패하면_실패를_알린다() {
        let r = run(updates: [errSecItemNotFound], adds: [errSecDiskFull])
        #expect(!r.ok)
        #expect(r.calls == ["update", "add"])
    }

    @Test func 만드는_사이_항목이_생겼으면_그_항목의_값을_바꾼다() {
        let r = run(updates: [errSecItemNotFound, errSecSuccess], adds: [errSecDuplicateItem])
        #expect(r.ok)
        #expect(r.calls == ["update", "add", "update"])
    }

    @Test func 다시_바꾸기도_실패하면_더_돌지_않고_실패를_알린다() {
        let r = run(updates: [errSecItemNotFound, errSecItemNotFound], adds: [errSecDuplicateItem])
        #expect(!r.ok)
        #expect(r.calls == ["update", "add", "update"])
    }
}
