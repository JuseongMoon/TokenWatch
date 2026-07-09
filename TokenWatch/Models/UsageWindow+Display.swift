//
//  UsageWindow+Display.swift
//  TokenWatch
//
//  UsageWindow의 리셋 시각/남은 시간 문자열 포맷팅. 리스트·상세에서 공용으로 쓴다.
//

import Foundation

extension UsageWindow {
    /// 리셋 정확 시각. 세션=시각만, 주간=날짜+시각. resetsAt 없으면 nil.
    var resetExactText: String? {
        guard let resetsAt else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        switch kind {
        case .session: f.dateFormat = "a h:mm"
        case .weekly:  f.dateFormat = "M월 d일 a h:mm"
        }
        return f.string(from: resetsAt)
    }

    /// 리셋까지 남은 시간. 세션=시·분, 주간=일·시간. 이미 지났으면 nil.
    func resetRemainingText(at now: Date = Date()) -> String? {
        guard let resetsAt, resetsAt > now else { return nil }
        switch kind {
        case .session:
            let c = Calendar.current.dateComponents([.hour, .minute], from: now, to: resetsAt)
            let h = max(0, c.hour ?? 0), m = max(0, c.minute ?? 0)
            return h > 0 ? "\(h)시간 \(m)분 남음" : "\(m)분 남음"
        case .weekly:
            let c = Calendar.current.dateComponents([.day, .hour], from: now, to: resetsAt)
            let d = max(0, c.day ?? 0), h = max(0, c.hour ?? 0)
            return d > 0 ? "\(d)일 \(h)시간 남음" : "\(h)시간 남음"
        }
    }

    /// "리셋 <시각> · <남은 시간>" 한 줄 요약. 이미 지났으면 "리셋됨".
    func resetSummary(at now: Date = Date()) -> String {
        guard let resetsAt else { return "" }
        if resetsAt <= now { return "리셋됨" }
        let exact = resetExactText ?? ""
        guard let remain = resetRemainingText(at: now), !remain.isEmpty else {
            return "리셋 \(exact)"
        }
        return "리셋 \(exact) · \(remain)"
    }
}
