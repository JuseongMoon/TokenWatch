//
//  ResetSchedulePolicy.swift
//  TokenWatch
//
//  정시 리셋 알림 "예약" 정책 — side-effect 없는 순수 로직. 각 창의 미래 resetsAt에
//  로컬 알림을 예약할 목표를 계산하고, 현재 등록(pending)된 것과 diff해 add/remove를 낸다.
//  iOS의 pending 로컬 알림 64개 상한을 넘지 않도록 per-agent·global cap을 둔다.
//  → AgentStore와 단위 테스트가 공유한다.
//

import Foundation

/// 예약할 알림 하나의 목표. 에이전트별로 같은 발화시각(분 버킷) 창들을 묶는다.
struct ScheduleTarget: Sendable, Equatable {
    let agentID: UUID
    let fireTime: Date
    let kinds: Set<WindowKind>
    let labels: [String]

    /// 결정론적 identifier. 분 버킷 epoch를 인코딩해 초 단위 흔들림에도 안정적이다.
    var identifier: String { ResetSchedulePolicy.identifier(agentID: agentID, fireTime: fireTime) }
}

enum ResetSchedulePolicy {
    /// 우리(리셋 알림) 소유 pending을 식별하는 접두어.
    static let idPrefix = "reset|"
    /// 에이전트당 예약할 미래 발화시각 최대 개수(세션+주간+모델별 몇 개를 커버하기 충분).
    static let perAgentLimit = 4
    /// 전 에이전트 합산 예약 상한(iOS 64 pending 상한 아래 헤드룸).
    static let globalLimit = 32

    static func identifier(agentID: UUID, fireTime: Date) -> String {
        "\(idPrefix)\(agentID.uuidString)|\(Int(fireTime.timeIntervalSince1970 / 60))"
    }

    /// 한 에이전트의 창들에서 예약 목표를 만든다.
    /// - 적격: `style == .gauge`(구독 사용률) + 해당 kind 토글 ON + 미래 resetsAt.
    ///   (`.creditGauge`/`.balance` 충전형은 타이머 리셋 개념이 없어 제외)
    /// - 같은 발화시각(분 버킷) 창들은 하나의 목표로 병합.
    /// - 가장 이른 `perAgentLimit`개만 남긴다.
    static func targets(agentID: UUID, windows: [UsageWindow], now: Date,
                        sessionOn: Bool, weeklyOn: Bool) -> [ScheduleTarget] {
        var byBucket: [Int: (fire: Date, kinds: Set<WindowKind>, labels: [String])] = [:]
        for w in windows where w.style == .gauge {
            guard (w.kind == .session ? sessionOn : weeklyOn) else { continue }
            guard let r = w.resetsAt, r > now else { continue }
            let bucket = Int(r.timeIntervalSince1970 / 60)
            var e = byBucket[bucket] ?? (r, [], [])
            if r < e.fire { e.fire = r }          // 같은 버킷이면 가장 이른 실제 시각을 트리거로
            e.kinds.insert(w.kind)
            e.labels.append(w.label)
            byBucket[bucket] = e
        }
        return byBucket.values
            .sorted { $0.fire < $1.fire }
            .prefix(perAgentLimit)
            .map { ScheduleTarget(agentID: agentID, fireTime: $0.fire,
                                  kinds: $0.kinds, labels: $0.labels.sorted()) }
    }

    /// 여러 에이전트의 목표를 전역 상한으로 자른다(가장 이른 것 우선).
    static func clampGlobal(_ targets: [ScheduleTarget]) -> [ScheduleTarget] {
        Array(targets.sorted { $0.fireTime < $1.fireTime }.prefix(globalLimit))
    }

    /// desired(원하는 id) vs pending(현재 등록된 id) diff.
    /// - add: desired 중 우리 소유 pending에 없는 것(호출측이 등록).
    /// - remove: 우리 소유(`reset|` 접두) pending 중 desired에 없는 것(호출측이 제거).
    ///   → resetsAt이 이동하면 옛 버킷 id가 desired에서 빠져 자동 제거된다(서버 재조정 반영).
    static func reconcile(desired: Set<String>, pending: [String]) -> (add: Set<String>, remove: [String]) {
        let ours = pending.filter { $0.hasPrefix(idPrefix) }
        let add = desired.subtracting(ours)
        let remove = ours.filter { !desired.contains($0) }
        return (add, remove)
    }
}
