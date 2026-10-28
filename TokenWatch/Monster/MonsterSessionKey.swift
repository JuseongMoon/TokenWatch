//
//  MonsterSessionKey.swift
//  TokenWatch
//
//  몬스터 출현 요청의 재료(리셋 버킷·주기·창 label·에이전트 키)를 Android와 비트 단위로 같게 만든다.
//  서버 문서 키도 같은 공식이라(SHA-256 hex) 로컬 매칭에 그대로 쓴다. 순수 함수 — 단위 테스트 대상.
//
//  - 리셋 시각은 300초 단위 반올림(소수점 초 흔들림에도 같은 세션이 같은 키).
//  - Copilot은 날짜만 주므로 표시용 resetsAt(기기 자정)이 아니라 그 날짜의 UTC 자정을 쓴다.
//  - Codex 추가 한도의 기본 label은 앱 언어를 따라 바뀌므로 언어 무관 상수로 바꾼다.
//  - 주기(periodSec)는 windowSeconds → 월간 표 → 창 종류 기본값 순서.
//

import CryptoKit
import Foundation

enum MonsterSessionKey {
    /// 리셋 시각 반올림 단위(300초).
    static let bucketMs: Int64 = 300_000
    /// 월간 창 주기(31일, 초).
    static let monthSeconds: Int64 = 31 * 86_400
    /// Codex 추가 한도의 언어 무관 label(키 전용 — 표시는 그대로).
    static let codexAdditionalLimit = "Additional limit"

    /// 키에 쓰는 창 label.
    static func keyLabel(provider: AgentProvider, label: String) -> String {
        guard provider == .codex else { return label }
        let localized = [Lang.ko, .en].map { L10n(lang: $0).codexAdditionalLimit }
        return localized.contains(label) ? codexAdditionalLimit : label
    }

    /// 키에 쓰는 리셋 시각(epoch ms). Copilot은 기기 시간대 날짜의 UTC 자정.
    static func keyResetsAtMs(provider: AgentProvider, resetsAt: Date, timeZone: TimeZone = .current) -> Int64 {
        if provider == .copilot {
            var local = Calendar(identifier: .gregorian)
            local.timeZone = timeZone
            let day = local.dateComponents([.year, .month, .day], from: resetsAt)
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            if let midnight = utc.date(from: day) { return epochMs(midnight) }
        }
        return epochMs(resetsAt)
    }

    /// 300초 단위 반올림(양수 epoch ms 전제).
    static func resetBucketMs(_ ms: Int64) -> Int64 {
        (ms + bucketMs / 2) / bucketMs * bucketMs
    }

    /// 창 주기(초) — 서버 정합성 검사(§8-4)에 보낸다.
    static func periodSec(provider: AgentProvider, label: String, windowSeconds: TimeInterval?,
                          kind: WindowKind) -> Int64 {
        if let seconds = windowSeconds, seconds > 0 { return Int64(seconds.rounded()) }
        switch provider {
        case .copilot:
            return monthSeconds
        case .kimi where label == "Current month" || label == "Current month (Code)":
            return monthSeconds
        case .elevenlabs where label == "Monthly characters":
            return monthSeconds
        default:
            return Int64(kind.defaultSeconds)
        }
    }

    // MARK: 키

    /// 기기 세션 장부 키(계정 무관, §8-8).
    static func completionLedgerKey(provider: AgentProvider, resetBucketMs: Int64) -> String {
        "\(provider.rawValue)|\(resetBucketMs)"
    }

    /// 서버 encounter 문서 키와 같은 해시(§15-4). 게스트는 uid 자리에 `guest`를 쓴다(로컬 전용).
    static func completionKey(uid: String, provider: AgentProvider, resetBucketMs: Int64) -> String {
        sha256Hex("\(uid)|\(provider.rawValue)|\(resetBucketMs)")
    }

    /// 확률 출현 키(§15-11): 에이전트 키와 그 추첨의 예정 시각. 게스트는 `guest`·에이전트 UUID를 쓴다.
    static func randomKey(uid: String, agentKey: String, drawAtMs: Int64) -> String {
        sha256Hex("\(uid)|rand|\(agentKey)|\(drawAtMs)")
    }

    /// 기기 원장의 에이전트 표기(UUID 소문자 — Android `UUID.toString()`과 같은 꼴).
    static func agentToken(_ id: UUID) -> String { id.uuidString.lowercased() }

    /// 서버로 보내는 에이전트 키. 계정마다 달라 계정 사이에 이어지지 않고, AI 계정 정보가 아니다.
    static func agentKey(uid: String, agentToken: String) -> String {
        sha256Hex("\(uid)|agent|\(agentToken)")
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func epochMs(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}

/// 몬스터가 붙을 수 있는 창인지(§8-1). 사용률 수치는 기기 밖으로 나가지 않는다.
enum MonsterEligibility {
    /// 완료 판정 기준 — 게이지 크리터와 같은 값.
    static let completionThreshold = 0.995

    /// 대상 창: 구독 게이지이고 미래 리셋이 있다(충전형·잔액은 제외).
    static func isTarget(_ window: UsageWindow, now: Date) -> Bool {
        guard window.style == .gauge, let resetsAt = window.resetsAt else { return false }
        return resetsAt > now
    }

    static func isCompleted(_ window: UsageWindow, now: Date) -> Bool {
        isTarget(window, now: now) && window.usedPercent / 100 >= completionThreshold
    }

    /// 확률 출현 후보. 100%가 된 창도 후보다 — 일찍 다 써도 리셋까지 추첨이 이어진다.
    /// 몬스터가 살아 있는 바·처치 1시간 안의 유령이 있는 바는 호출측(MonsterStore)이 거른다.
    static func isRandomCandidate(_ window: UsageWindow, minUsedPercent: Double, now: Date) -> Bool {
        isTarget(window, now: now) && window.usedPercent >= minUsedPercent
    }

    /// 같은 AI 계정으로 보이는 에이전트의 표식(기기 안에서만 쓴다). 같은 계정을 여러 번 추가하면 대상 창의
    /// label·리셋 시각·사용률이 똑같으므로 확률 추첨은 그중 하나만 한다. 서로 다른 계정은 숫자가 달라 갈린다.
    static func accountSignature(provider: AgentProvider, windows: [UsageWindow], now: Date) -> String {
        let parts = windows.compactMap { window -> String? in
            guard isTarget(window, now: now), let resetsAt = window.resetsAt else { return nil }
            let reset = MonsterSessionKey.resetBucketMs(
                MonsterSessionKey.keyResetsAtMs(provider: provider, resetsAt: resetsAt))
            return "\(window.label)|\(reset)|\(Int(window.usedPercent.rounded()))"
        }
        return ([provider.rawValue] + parts.sorted()).joined(separator: "\n")
    }
}
