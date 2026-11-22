//
//  LoginFunnelTracker.swift
//  TokenWatch
//
//  `login_abandon`의 진단값 두 개(Android와 같은 의미):
//   - `elapsed`: 그 provider의 마지막 `login_start`부터 이탈 기록까지의 벽시계 시간(앱이 백그라운드였던
//     시간 포함 — 메일로 인증 코드를 확인하러 다녀온 시간도 들어간다). 10초 미만 `lt10s`,
//     10~60초(60 포함) `10_60s`, 60초 초과 `gt60s`.
//   - `attempt`: 마지막 `login_success` 이후 같은 provider의 `login_start` 횟수. `1`·`2`·`3`(3 이상은 3).
//
//  추가 시트의 `@State`가 아니라 앱 범위에 둔다 — 시트를 닫았다 다시 열어도 횟수가 이어져야 한다.
//  그 provider로 로그인에 성공하면 초기화하고, 앱을 다시 시작하면 처음부터 센다(저장하지 않는다).
//  값은 기기 밖으로 나가는 `login_abandon` 파라미터(열거 문자열)로만 쓰이고 시각 자체는 보내지 않는다.
//

import Foundation

/// `elapsed` 구간.
nonisolated enum LoginElapsedBucket: String, Sendable, CaseIterable {
    case under10s = "lt10s"
    case from10To60s = "10_60s"
    case over60s = "gt60s"

    init(seconds: TimeInterval) {
        // 시계가 뒤로 바뀌어 음수가 되면 0으로 본다.
        let s = max(0, seconds)
        if s < 10 {
            self = .under10s
        } else if s <= 60 {
            self = .from10To60s
        } else {
            self = .over60s
        }
    }
}

@MainActor
final class LoginFunnelTracker {
    static let shared = LoginFunnelTracker()

    /// 로그인 이탈 진단값.
    struct AbandonContext: Equatable {
        let elapsed: LoginElapsedBucket
        /// 1...3 (3 이상은 3).
        let attempt: Int

        /// `attempt` 파라미터 값(문자열).
        var attemptTag: String { String(attempt) }
    }

    private let now: () -> Date
    private var lastStart: [AgentProvider: Date] = [:]
    private var startsSinceSuccess: [AgentProvider: Int] = [:]

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// `login_start`를 기록할 때 함께 부른다.
    func recordStart(_ provider: AgentProvider) {
        lastStart[provider] = now()
        startsSinceSuccess[provider, default: 0] += 1
    }

    /// `login_success`를 기록할 때 함께 부른다 — 그 provider의 횟수를 처음부터 다시 센다.
    func recordSuccess(_ provider: AgentProvider) {
        lastStart[provider] = nil
        startsSinceSuccess[provider] = nil
    }

    /// 지금 이탈을 기록한다면 실을 값. 시작 기록이 없으면(드묾) 방금 시작한 1회로 본다.
    func abandonContext(for provider: AgentProvider) -> AbandonContext {
        let elapsed = lastStart[provider].map { now().timeIntervalSince($0) } ?? 0
        let starts = startsSinceSuccess[provider] ?? 0
        return AbandonContext(elapsed: LoginElapsedBucket(seconds: elapsed),
                              attempt: min(max(starts, 1), 3))
    }
}
