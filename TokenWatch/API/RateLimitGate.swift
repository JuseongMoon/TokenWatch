//
//  RateLimitGate.swift
//  TokenWatch
//
//  Claude `/api/oauth/usage`는 공격적으로 rate-limit(429)한다. 429를 만나면
//  Retry-After(없으면 +5분)만큼 호출을 멈추고, 그동안 마지막 성공 스냅샷을
//  계속 표시한다. (참고: TokenBar agent_usage.rs ClaudeUsageGate)
//

import Foundation

actor RateLimitGate {
    static let shared = RateLimitGate()

    private var blockedUntil: [UUID: Date] = [:]
    private var lastGood: [UUID: AgentSnapshot] = [:]

    private static let defaultBackoff: TimeInterval = 300  // 5분

    /// 아직 차단 중이면 해제 시각을 반환. 지났으면 해제하고 nil.
    func blocked(for id: UUID) -> Date? {
        guard let until = blockedUntil[id] else { return nil }
        if until > Date() { return until }
        blockedUntil[id] = nil
        return nil
    }

    func recordRateLimit(for id: UUID, retryAfter: Date?) {
        let until = (retryAfter.flatMap { $0 > Date() ? $0 : nil })
            ?? Date().addingTimeInterval(Self.defaultBackoff)
        blockedUntil[id] = until
    }

    func recordSuccess(for id: UUID, _ snapshot: AgentSnapshot) {
        blockedUntil[id] = nil
        lastGood[id] = snapshot
    }

    func lastGood(for id: UUID) -> AgentSnapshot? { lastGood[id] }
}
