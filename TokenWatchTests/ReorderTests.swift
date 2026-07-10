//
//  ReorderTests.swift
//  TokenWatchTests
//
//  리스트 순서 변경(위/아래 화살표)의 순수 로직 검증:
//  Array.reordered(movingID:by:) — 스왑·경계·미존재 id를 결정적으로 확인한다.
//

import Testing
import Foundation
@testable import TokenWatch

struct ReorderTests {

    /// provider 순서만 다른 3개짜리 리스트(각 항목은 고유 UUID를 갖는다).
    private func list(_ providers: [AgentProvider]) -> [Agent] {
        providers.map { Agent(provider: $0) }
    }

    // MARK: 정상 이동

    @Test func moveUpSwapsWithPrevious() {
        let l = list([.claude, .codex, .cursor])
        let moved = l.reordered(movingID: l[1].id, by: -1)
        #expect(moved.map(\.provider) == [.codex, .claude, .cursor])
    }

    @Test func moveDownSwapsWithNext() {
        let l = list([.claude, .codex, .cursor])
        let moved = l.reordered(movingID: l[1].id, by: 1)
        #expect(moved.map(\.provider) == [.claude, .cursor, .codex])
    }

    // MARK: 경계(무시되어야 함)

    @Test func moveUpAtTopIsNoOp() {
        let l = list([.claude, .codex])
        let moved = l.reordered(movingID: l[0].id, by: -1)
        #expect(moved.map(\.id) == l.map(\.id))
    }

    @Test func moveDownAtBottomIsNoOp() {
        let l = list([.claude, .codex])
        let moved = l.reordered(movingID: l[1].id, by: 1)
        #expect(moved.map(\.id) == l.map(\.id))
    }

    // MARK: 예외 상황

    @Test func unknownIDIsNoOp() {
        let l = list([.claude, .codex])
        let moved = l.reordered(movingID: UUID(), by: -1)
        #expect(moved.map(\.id) == l.map(\.id))
    }

    @Test func singleElementStaysPut() {
        let l = list([.claude])
        #expect(l.reordered(movingID: l[0].id, by: -1).map(\.id) == l.map(\.id))
        #expect(l.reordered(movingID: l[0].id, by: 1).map(\.id) == l.map(\.id))
    }

    /// 위로 올렸다 다시 내리면 원래 순서로 복귀한다(왕복 불변식).
    @Test func moveUpThenDownRestoresOrder() {
        let l = list([.claude, .codex, .cursor])
        let up = l.reordered(movingID: l[2].id, by: -1)
        let backDown = up.reordered(movingID: l[2].id, by: 1)
        #expect(backDown.map(\.id) == l.map(\.id))
    }
}
