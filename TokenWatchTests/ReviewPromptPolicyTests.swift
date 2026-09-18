//
//  ReviewPromptPolicyTests.swift
//  TokenWatchTests
//
//  리뷰 프롬프트 판정(ReviewPromptPolicy)과 실행 기록(ReviewPromptState) 검증.
//  - 조건 하나라도 빠지면 false(미활성·3일 미만·5회 미만·이미 표시·카드 에러·첫 실행 기록 없음)
//  - 경계(정확히 3일·5회)는 true
//  - recordLaunch: 첫 실행 시각은 한 번만, 카운트는 매번 증가
//

import Testing
import Foundation
@testable import TokenWatch

struct ReviewPromptPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var threeDaysAgo: Date { now.addingTimeInterval(-3 * 86_400) }

    private func prompt(activated: Bool = true, firstLaunchAt: Date? = nil, launchCount: Int = 5,
                        alreadyPrompted: Bool = false, healthy: Bool = true) -> Bool {
        ReviewPromptPolicy.shouldPrompt(activated: activated,
                                        firstLaunchAt: firstLaunchAt ?? threeDaysAgo,
                                        launchCount: launchCount, alreadyPrompted: alreadyPrompted,
                                        allSnapshotsHealthy: healthy, now: now)
    }

    @Test func boundaryPasses() {
        #expect(prompt())
    }

    @Test func eachMissingConditionBlocks() {
        #expect(!prompt(activated: false))
        #expect(!prompt(firstLaunchAt: threeDaysAgo.addingTimeInterval(1)))
        #expect(!prompt(launchCount: 4))
        #expect(!prompt(alreadyPrompted: true))
        #expect(!prompt(healthy: false))
    }

    @Test func missingFirstLaunchBlocks() {
        #expect(!ReviewPromptPolicy.shouldPrompt(activated: true, firstLaunchAt: nil, launchCount: 9,
                                                 alreadyPrompted: false, allSnapshotsHealthy: true,
                                                 now: now))
    }

    @Test func recordLaunchKeepsFirstDateAndCounts() {
        let suite = "ReviewPromptPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = ReviewPromptState(defaults: defaults)

        #expect(state.firstLaunchAt == nil)
        #expect(state.launchCount == 0)
        state.recordLaunch(now: threeDaysAgo)
        state.recordLaunch(now: now)
        #expect(state.firstLaunchAt == threeDaysAgo)
        #expect(state.launchCount == 2)

        #expect(!state.prompted)
        state.markPrompted()
        #expect(state.prompted)
    }
}
