//
//  ReviewPromptPolicy.swift
//  TokenWatch
//
//  App Store 리뷰 요청 시점 판정(순수 규칙)과 그 근거가 되는 실행 기록.
//  - 시스템 프롬프트는 연 3회로 제한되므로 설치당 1회만, 가치를 이미 확인한 사용자에게만 띄운다:
//    활성화 완료 + 첫 실행 후 3일 + 콜드 스타트 5회 + 지금 모든 카드가 정상.
//  - 설정 INFO의 `rate on App Store` 행은 이 규칙과 무관하게 언제든 쓸 수 있다.
//

import Foundation

nonisolated enum ReviewPromptPolicy {
    static let minDaysSinceFirstLaunch = 3
    static let minLaunches = 5

    /// App Store 리뷰 작성 화면으로 바로 가는 링크(지역 스토어프런트는 App Store가 고른다).
    static let writeReviewURL = URL(string: "https://apps.apple.com/app/id6795418418?action=write-review")!

    static func shouldPrompt(activated: Bool, firstLaunchAt: Date?, launchCount: Int,
                             alreadyPrompted: Bool, allSnapshotsHealthy: Bool, now: Date) -> Bool {
        guard activated, !alreadyPrompted, allSnapshotsHealthy,
              launchCount >= minLaunches, let firstLaunchAt else { return false }
        return now.timeIntervalSince(firstLaunchAt) >= TimeInterval(minDaysSinceFirstLaunch) * 86_400
    }
}

/// 리뷰 프롬프트 판정에 쓰는 실행 기록. 기존 사용자는 이 기능이 들어간 버전의 첫 실행부터 센다.
nonisolated struct ReviewPromptState {
    static let firstLaunchKey = "tokenwatch.review.firstLaunchAt"
    static let launchCountKey = "tokenwatch.review.launchCount"
    static let promptedKey = "tokenwatch.review.prompted"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var firstLaunchAt: Date? { defaults.object(forKey: Self.firstLaunchKey) as? Date }
    var launchCount: Int { defaults.integer(forKey: Self.launchCountKey) }
    var prompted: Bool { defaults.bool(forKey: Self.promptedKey) }

    /// 콜드 스타트마다 1회. 첫 실행 시각은 처음 한 번만 기록한다.
    func recordLaunch(now: Date = Date()) {
        if firstLaunchAt == nil { defaults.set(now, forKey: Self.firstLaunchKey) }
        defaults.set(launchCount + 1, forKey: Self.launchCountKey)
    }

    func markPrompted() { defaults.set(true, forKey: Self.promptedKey) }
}
