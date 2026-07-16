//
//  ResetDetector.swift
//  TokenWatch
//
//  사용량 창의 "리셋" 감지 — side-effect 없는 순수 로직. 직전 관측(baseline)과 현재
//  관측을 비교해, "예정보다 이른(서프라이즈) 리셋"만 즉시 알림 이벤트로 낸다.
//  정시 리셋은 예약형 로컬 알림(ResetSchedulePolicy)이 소유하므로 여기서 억제한다.
//  → AgentStore와 단위 테스트가 공유한다(AutoRefreshPolicy와 같은 순수 정책 패턴).
//

import Foundation

/// 한 창(window)의 관측 스냅샷 — 리셋 판정에 필요한 최소 정보. UserDefaults에 영속한다.
struct WindowObservation: Codable, Sendable, Equatable {
    var resetsAt: Date?
    var usedPercent: Double
}

/// 즉시 발화할 리셋 이벤트 하나. 한 에이전트에서 이번에 감지된 서프라이즈 리셋 창들을
/// 하나로 묶은 결과다(사용자 결정: 에이전트별 묶음).
struct ResetEvent: Sendable, Equatable {
    /// 대표 경계 시각(묶인 창 중 가장 이른 리셋 경계). 알림 식별/로깅용 — 문구는 정적.
    let fireTime: Date
    /// 묶인 창들의 종류(세션/주간). 본문 문구 선택에 쓴다.
    let kinds: Set<WindowKind>
    /// 묶인 창 라벨들(정렬됨).
    let labels: [String]
}

/// 리셋 감지 순수 정책.
enum ResetDetector {
    /// 보조 신호(resetsAt이 전진하지 않았을 때): 사용률이 이만큼(%p) 이상 급감하고,
    static let usedDropThreshold: Double = 20
    /// 그리고 이 값(%) 이하로 착지하면 리셋으로 본다. (약간의 감소를 리셋으로 오인하지 않게)
    static let usedLandingCeiling: Double = 5
    /// 정시/서프라이즈 판정에 허용하는 서버-기기 시계 오차(초).
    static let clockSkew: TimeInterval = 120

    /// 한 에이전트의 (직전 baseline → 현재) 관측을 비교한다.
    /// - Parameters:
    ///   - previous: 이 에이전트의 직전 관측 맵(key = "UUID|label"). 비어 있으면 첫 관측.
    ///   - current: 이번 관측 맵.
    ///   - kindOf: key → WindowKind (본문 문구용).
    /// - Returns: (즉시 발화할 이벤트 0~1개, 저장할 새 baseline = current)
    ///   - 직전 관측이 없는 창(첫 fetch·새 창)은 이벤트 없이 baseline만 → **처음 추가 시 무알림**.
    ///   - resetsAt 전진(주 신호) 또는 usedPercent 급감(보조 신호)이면 리셋.
    ///   - 단, `now >= 직전 resetsAt - skew`(정시)면 예약형이 이미 발화했으므로 억제한다.
    static func detect(previous: [String: WindowObservation],
                       current: [String: WindowObservation],
                       now: Date,
                       kindOf: (String) -> WindowKind)
        -> (events: [ResetEvent], baseline: [String: WindowObservation]) {

        var kinds: Set<WindowKind> = []
        var labels: [String] = []
        var earliest: Date?

        for (key, cur) in current {
            guard let prev = previous[key] else { continue }   // 첫 관측 → baseline만 (오탐 방지)
            guard let boundary = resetBoundary(previous: prev, current: cur, now: now) else { continue }
            // 정시 리셋(예약형이 소유) → 억제. 서버가 예정보다 일찍 리셋한 경우만 즉시 발화.
            if let pr = prev.resetsAt, now >= pr - clockSkew { continue }
            kinds.insert(kindOf(key))
            labels.append(windowLabel(fromKey: key))
            if earliest == nil || boundary < earliest! { earliest = boundary }
        }

        guard !labels.isEmpty else { return ([], current) }
        let event = ResetEvent(fireTime: earliest ?? now, kinds: kinds, labels: labels.sorted())
        return ([event], current)
    }

    /// 리셋 경계 시각을 판정한다. 리셋이 아니면 nil.
    /// - 주 신호: resetsAt 전진(직전 < 현재) → 경계 = 직전 resetsAt(예약형이 소유했던 시각).
    /// - 보조 신호: 대폭 급감 → 경계 = 직전 resetsAt ?? now. (resetsAt 없는 창의 유일한 감지 수단)
    static func resetBoundary(previous p: WindowObservation, current c: WindowObservation, now: Date) -> Date? {
        if let pr = p.resetsAt, let cr = c.resetsAt, cr > pr { return pr }
        if p.usedPercent - c.usedPercent >= usedDropThreshold, c.usedPercent <= usedLandingCeiling {
            return p.resetsAt ?? now
        }
        return nil
    }

    /// 창 키 "UUID|label"에서 label 부분만 뽑는다. 구분자가 없으면 원본 그대로.
    static func windowLabel(fromKey key: String) -> String {
        guard let sep = key.firstIndex(of: "|") else { return key }
        return String(key[key.index(after: sep)...])
    }
}
