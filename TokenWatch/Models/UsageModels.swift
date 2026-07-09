//
//  UsageModels.swift
//  TokenWatch
//
//  Claude usage(oauth/usage) 응답과, UI가 소비하는 정규화된 사용량 창(window) 모델.
//

import Foundation

/// 창 종류 — 리셋 시간 표기 방식을 결정한다.
enum WindowKind: Sendable, Hashable {
    case session   // 5시간 창 → "N시간 남음"
    case weekly    // 7일 창 → "N일 N시간 남음"

    /// 기본 창 주기(초). API가 명시적 주기를 주지 않는 Claude에서 사용한다.
    var defaultSeconds: TimeInterval {
        switch self {
        case .session: return 5 * 3600        // 18,000초 (5시간)
        case .weekly:  return 7 * 24 * 3600   // 604,800초 (7일)
        }
    }
}

/// UI에 표시되는 정규화된 사용량 창 하나.
/// (예: "Current session" 15% used → remainingPercent 85)
struct UsageWindow: Identifiable, Sendable, Hashable {
    let label: String
    /// 0...100
    let usedPercent: Double
    /// 리셋 시각(ISO8601 파싱 결과). 없을 수 있다.
    let resetsAt: Date?
    let kind: WindowKind
    /// 이 창의 전체 주기(초). 시간 경과 마커(노란선) 계산에 사용. 모르면 nil.
    let windowSeconds: TimeInterval?

    init(label: String, usedPercent: Double, resetsAt: Date?, kind: WindowKind,
         windowSeconds: TimeInterval? = nil) {
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.kind = kind
        self.windowSeconds = windowSeconds
    }

    /// 0...100
    var remainingPercent: Double { max(0, 100 - usedPercent) }
    var id: String { label }

    /// 주어진 시각 기준, 창 안에서 흐른 시간의 비율(0...1) — "현재 시각" 마커 위치.
    /// 예) 5시간 창에서 2.5시간 남으면 0.5, 1시간 남으면 0.8.
    func elapsedFraction(at now: Date = Date()) -> Double? {
        guard let resetsAt, let windowSeconds, windowSeconds > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        let elapsed = windowSeconds - remaining
        return min(max(elapsed / windowSeconds, 0), 1)
    }

    /// 사용 속도 편차(%p): (사용률 − 시간경과율)×100. 양수=시간보다 빠름, 음수=여유.
    func paceDelta(at now: Date = Date()) -> Double? {
        guard let elapsed = elapsedFraction(at: now) else { return nil }
        return usedPercent - elapsed * 100
    }
}

/// 한 에이전트의 사용량 스냅샷 (성공 또는 실패).
struct AgentSnapshot: Sendable {
    var windows: [UsageWindow]
    var planLabel: String?
    var fetchedAt: Date
    var error: String?
}

// MARK: - Claude oauth/usage 응답 디코딩

/// Claude `/api/oauth/usage` 응답. 최상위 키 이름(예: `five_hour`, `seven_day`,
/// `seven_day_fable`)은 시간이 지나며 늘어나므로, 고정 필드로 파싱하지 않고
/// "모든 창 형태 키"를 동적으로 수집한 뒤 원하는 것을 골라 쓴다.
struct ClaudeUsageResponse: Decodable, Sendable {
    /// key(원본 스네이크케이스) -> 창
    let windows: [String: ClaudeWindow]

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var result: [String: ClaudeWindow] = [:]
        for key in container.allKeys {
            // 값이 { utilization, resets_at } 형태인 것만 창으로 취급.
            // extra_usage 같은 다른 오브젝트는 utilization이 없으면 무시된다.
            if let window = try? container.decode(ClaudeWindow.self, forKey: key),
               window.utilization != nil {
                result[key.stringValue] = window
            }
        }
        self.windows = result
    }
}

/// 개별 창. `utilization`은 0~100(used %)로 온다.
struct ClaudeWindow: Decodable, Sendable {
    let utilization: Double?
    let resetsAt: Date?

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // utilization은 숫자 또는 문자열로 올 수 있어 방어적으로 파싱.
        if let d = try? c.decode(Double.self, forKey: .utilization) {
            utilization = d
        } else if let s = try? c.decode(String.self, forKey: .utilization), let d = Double(s) {
            utilization = d
        } else {
            utilization = nil
        }
        if let s = try? c.decode(String.self, forKey: .resetsAt) {
            resetsAt = ISO8601DateFormatter.tokenwatch.date(from: s)
                ?? ISO8601DateFormatter.tokenwatchNoFraction.date(from: s)
        } else {
            resetsAt = nil
        }
    }
}

extension ISO8601DateFormatter {
    static let tokenwatch: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let tokenwatchNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - 응답 -> UI 창 매핑

enum ClaudeUsageMapper {
    /// 스크린샷의 3개 창(Current session / Current week all models / Current week Fable)을
    /// 우선 노출하고, 그 외 발견된 7일 모델 창들도 뒤에 붙인다.
    static func windows(from response: ClaudeUsageResponse) -> [UsageWindow] {
        var out: [UsageWindow] = []
        var consumed: Set<String> = []

        func take(_ key: String, label: String, kind: WindowKind) {
            guard let w = response.windows[key], let util = w.utilization else { return }
            out.append(UsageWindow(label: label, usedPercent: util.clamped(0, 100),
                                   resetsAt: w.resetsAt, kind: kind,
                                   windowSeconds: kind.defaultSeconds))
            consumed.insert(key)
        }

        take("five_hour", label: "Current session", kind: .session)
        take("seven_day", label: "Current week (all models)", kind: .weekly)

        // Fable 주간 창: 키 이름이 확정적이지 않을 수 있어 "fable" 포함 키를 탐색.
        if let fableKey = response.windows.keys.first(where: { $0.lowercased().contains("fable") }) {
            take(fableKey, label: "Current week (Fable)", kind: .weekly)
        }

        // 남은 7일 모델별 창(Opus/Sonnet 등)도 정보로 추가 노출.
        let extraLabels: [String: String] = [
            "seven_day_opus": "Current week (Opus)",
            "seven_day_sonnet": "Current week (Sonnet)",
        ]
        for (key, label) in extraLabels where !consumed.contains(key) {
            take(key, label: label, kind: .weekly)
        }

        return out
    }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { min(max(self, lo), hi) }
}
