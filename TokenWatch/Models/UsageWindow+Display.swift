//
//  UsageWindow+Display.swift
//  TokenWatch
//
//  UsageWindow의 리셋 시각/남은 시간 문자열 포맷팅. 리스트·상세에서 공용으로 쓴다.
//

import Foundation

extension UsageWindow {
    /// 리셋 정확 시각. 세션=시각만, 주간=날짜+시각. resetsAt 없으면 nil.
    func resetExactText(_ loc: L10n) -> String? {
        guard let resetsAt else { return nil }
        return loc.resetExact(resetsAt, kind: kind)
    }

    /// 리셋까지 남은 시간. 세션=시·분, 주간=일·시간. 이미 지났으면 nil.
    func resetRemainingText(_ loc: L10n, at now: Date = Date()) -> String? {
        guard let resetsAt, resetsAt > now else { return nil }
        switch kind {
        case .session:
            let c = Calendar.current.dateComponents([.hour, .minute], from: now, to: resetsAt)
            return loc.resetRemaining(kind: .session, days: 0,
                                      hours: max(0, c.hour ?? 0), minutes: max(0, c.minute ?? 0))
        case .weekly:
            let c = Calendar.current.dateComponents([.day, .hour], from: now, to: resetsAt)
            return loc.resetRemaining(kind: .weekly, days: max(0, c.day ?? 0),
                                      hours: max(0, c.hour ?? 0), minutes: 0)
        }
    }

    /// "리셋 <시각> · <남은 시간>" 한 줄 요약. 이미 지났으면 "리셋됨".
    func resetSummary(_ loc: L10n, at now: Date = Date()) -> String {
        guard let resetsAt else { return "" }
        if resetsAt <= now { return loc.resetDone }
        let exact = resetExactText(loc) ?? ""
        let remain = resetRemainingText(loc, at: now)
        return loc.resetLine(exact: exact, remain: (remain?.isEmpty == false) ? remain : nil)
    }
}
