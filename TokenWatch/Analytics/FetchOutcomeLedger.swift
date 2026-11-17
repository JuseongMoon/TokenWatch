//
//  FetchOutcomeLedger.swift
//  TokenWatch
//
//  `usage_fetch_error`·`usage_fetch_recover`를 계정(카드)별 상태 "전이"에만 보내도록, 카드마다 마지막
//  조회 결과를 기기(UserDefaults)에 저장한다. 메모리(직전 스냅샷)에만 두면 앱을 새로 띄울 때마다
//  같은 오류가 다시 기록된다. 지표 의미: 계정별 오류 전이 수(사람 수 아님).
//
//  저장 값은 열거 문자열뿐이다 — `ok`, `FetchErrorReason` rawValue, `paused`(기준 모름).
//  자격증명·사용률 수치·원문 메시지는 저장하지 않는다. 키 하나(`tokenwatch.fetchOutcome.v1`)에
//  [카드 UUID: 값] 사전으로 둔다.
//
//  전이 규칙(Android와 같음):
//   - 이전 없음·ok → 오류: `usage_fetch_error` 1회
//   - 이전 오류 → 다른 사유의 오류: 새 오류로 1회
//   - 이전 오류 → ok: `usage_fetch_recover` 1회
//   - 같은 상태 유지, 이전 없음 → ok: 기록 없음(기준만 저장)
//  분석 수집이 꺼진 동안의 결과는 비교·저장하지 않고, 그 카드를 `paused`로만 표시한다.
//  수집이 다시 켜진 뒤 그 카드의 첫 결과는 기준만 저장하고 이벤트를 보내지 않는다(짝 없는 recover 방지).
//  데모 진입 때도 모든 카드를 `paused`로 표시한다 — 데모를 나온 뒤 첫 결과는 기준만(같은 오류 재전송 방지).
//  카드 삭제·지원 종료 provider 정리 때는 그 카드 값을 지운다.
//
//  원자성: 호출자(`AgentStore.refresh`)가 MainActor에서 읽기 → 비교 → 저장을 `await` 없이 한 번에 하고,
//  같은 카드의 조회는 동시에 하나뿐이다(`loadingIDs`). 이벤트 전송은 저장 뒤에 호출자가 한다.
//  종료 타이밍에 따라 이벤트 일부가 빠질 수 있다(정확히 한 번 전송은 목표가 아니다).
//

import Foundation

@MainActor
final class FetchOutcomeLedger {
    /// 저장 뒤 보낼 이벤트.
    enum Transition: Equatable {
        case error(FetchErrorReason)
        case recover
    }

    static let storageKey = "tokenwatch.fetchOutcome.v1"
    static let okValue = "ok"
    /// 분석 수집이 꺼진 동안 결과가 있었다 — 저장된 기준을 믿을 수 없다.
    static let pausedValue = "paused"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: 전이 판정(순수 함수)

    /// 저장된 이전 값과 이번 결과로 보낼 이벤트를 정한다.
    /// - Parameter current: 오류면 사유, 정상이면 nil.
    static func transition(previous: String?, current: FetchErrorReason?) -> Transition? {
        let currentValue = current?.rawValue ?? okValue
        if previous == pausedValue || previous == currentValue { return nil }
        if let current { return .error(current) }      // 없음·ok·다른 사유 → 오류
        guard let previous, previous != okValue else { return nil }   // 없음 → ok: 기준만
        return .recover                                 // 오류 → ok
    }

    // MARK: 기록

    /// 이번 결과를 저장하고, 보낼 이벤트를 돌려준다(저장을 마친 뒤 돌려준다 — 전송은 호출자가 그 다음에 한다).
    /// - Parameters:
    ///   - current: 오류면 사유, 정상이면 nil. 지난 정상값 위에 오류만 덧입힌 경우(429 등)도 오류다.
    ///   - collecting: 지금 분석이 실제로 수집되는지. false면 비교·저장하지 않고 `paused`로만 표시한다.
    func record(_ current: FetchErrorReason?, for agentID: UUID, collecting: Bool) -> Transition? {
        var values = load()
        let key = agentID.uuidString
        guard collecting else {
            if values[key] != Self.pausedValue {
                values[key] = Self.pausedValue
                save(values)
            }
            return nil
        }
        let previous = values[key]
        let transition = Self.transition(previous: previous, current: current)
        let currentValue = current?.rawValue ?? Self.okValue
        if previous != currentValue {
            values[key] = currentValue
            save(values)
        }
        return transition
    }

    /// 저장된 값(테스트·진단용).
    func value(for agentID: UUID) -> String? {
        load()[agentID.uuidString]
    }

    // MARK: 정리

    /// 지운 카드의 상태를 지운다.
    func remove(_ agentIDs: [UUID]) {
        var values = load()
        let before = values.count
        for id in agentIDs { values[id.uuidString] = nil }
        guard values.count != before else { return }
        save(values)
    }

    /// 모든 카드를 `paused`(기준 모름)로 표시한다(데모 진입). 저장된 카드와 넘겨받은 카드(아직 결과가
    /// 없던 카드 포함) 모두 — 데모를 나온 뒤 각 카드의 첫 결과는 기준만 잡고 이벤트를 보내지 않는다.
    func markAllPaused(_ agentIDs: [UUID]) {
        var values = load()
        for key in values.keys { values[key] = Self.pausedValue }
        for id in agentIDs { values[id.uuidString] = Self.pausedValue }
        save(values)
    }

    // MARK: 저장소

    private func load() -> [String: String] {
        (defaults.dictionary(forKey: Self.storageKey) as? [String: String]) ?? [:]
    }

    private func save(_ values: [String: String]) {
        if values.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else {
            defaults.set(values, forKey: Self.storageKey)
        }
    }
}

/// 조회 전이 이벤트를 보낼 곳 — 앱은 `AnalyticsService`, 테스트는 기록용 가짜를 쓴다.
struct FetchOutcomeAnalytics {
    var isCollecting: @MainActor () -> Bool
    var log: @MainActor (AnalyticsEvent) -> Void

    static var live: FetchOutcomeAnalytics {
        FetchOutcomeAnalytics(isCollecting: { AnalyticsService.shared.isCollecting },
                              log: { AnalyticsService.shared.log($0) })
    }
}
