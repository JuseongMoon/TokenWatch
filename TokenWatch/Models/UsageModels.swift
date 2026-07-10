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

/// 창 표시 방식.
/// - gauge: 사용률(0~100%) 게이지. 한도가 있는 구독/쿼터형(Claude/Codex/Copilot 등).
/// - balance: 절대 잔액 텍스트(예: "6.50 USD", "1.2M pts"). 한도 없는 선불 크레딧형.
enum UsageStyle: Sendable, Hashable {
    case gauge
    case balance
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
    /// 표시 방식(게이지 vs 잔액 텍스트).
    let style: UsageStyle
    /// balance 스타일에서 표시할 절대값 문자열(예: "6.50 USD"). gauge에선 미사용.
    let valueText: String?

    init(label: String, usedPercent: Double, resetsAt: Date?, kind: WindowKind,
         windowSeconds: TimeInterval? = nil, style: UsageStyle = .gauge,
         valueText: String? = nil) {
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.kind = kind
        self.windowSeconds = windowSeconds
        self.style = style
        self.valueText = valueText
    }

    /// 0...100
    var remainingPercent: Double { max(0, 100 - usedPercent) }
    var id: String { label }

    /// 전혀 쓰지 않은(사용률 0%) 게이지 창인지. "미사용 창 숨김" 설정의 판정 기준.
    /// 잔액(balance) 스타일은 "0% 그래프" 개념이 없으므로 항상 false(숨기지 않음).
    var isUnused: Bool { style == .gauge && usedPercent <= 0 }

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
    /// 새 형식: 모든 사용량 창을 담은 배열(session / weekly_all / weekly_scoped …).
    let limits: [ClaudeLimit]
    /// 구형 형식: key(원본 스네이크케이스) -> 창. limits가 비었을 때만 fallback으로 쓴다.
    let windows: [String: ClaudeWindow]

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)

        // 새 형식: limits 배열.
        if let limitsKey = DynamicKey(stringValue: "limits") {
            self.limits = (try? container.decode([ClaudeLimit].self, forKey: limitsKey)) ?? []
        } else {
            self.limits = []
        }

        // 구형 형식: utilization/resets_at을 가진 최상위 창 키들.
        var result: [String: ClaudeWindow] = [:]
        for key in container.allKeys where key.stringValue != "limits" {
            if let window = try? container.decode(ClaudeWindow.self, forKey: key),
               window.utilization != nil || window.resetsAt != nil {
                result[key.stringValue] = window
            }
        }
        self.windows = result
    }
}

/// 새 형식 `limits` 배열의 원소 — Claude /usage가 보여주는 창 하나.
struct ClaudeLimit: Decodable, Sendable {
    let kind: String        // "session" | "weekly_all" | "weekly_scoped" …
    let group: String       // "session" | "weekly"
    let percent: Double     // 0~100 used %
    let resetsAt: Date?
    let scope: Scope?

    struct Scope: Decodable, Sendable {
        let model: Model?
        struct Model: Decodable, Sendable {
            let displayName: String?
            enum CodingKeys: String, CodingKey { case displayName = "display_name" }
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, scope
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        group = (try? c.decode(String.self, forKey: .group)) ?? ""
        percent = (try? c.decode(Double.self, forKey: .percent)) ?? 0
        scope = try? c.decode(Scope.self, forKey: .scope)
        if let s = try? c.decode(String.self, forKey: .resetsAt) {
            resetsAt = ISO8601DateFormatter.tokenwatch.date(from: s)
                ?? ISO8601DateFormatter.tokenwatchNoFraction.date(from: s)
        } else {
            resetsAt = nil
        }
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
    /// 새 형식(limits 배열)이 있으면 그것으로 매핑하고,
    /// 없으면 구형 키(five_hour / seven_day / *fable*)로 fallback한다.
    static func windows(from response: ClaudeUsageResponse) -> [UsageWindow] {
        // ── 새 형식 우선: limits 배열을 순서대로 매핑 ──
        if !response.limits.isEmpty {
            return response.limits.map { limit in
                let kind: WindowKind = (limit.group == "session") ? .session : .weekly
                let label: String
                switch limit.kind {
                case "session":    label = "Current session"
                case "weekly_all": label = "Current week (all models)"
                case "weekly_scoped":
                    let model = limit.scope?.model?.displayName ?? "scoped"
                    label = "Current week (\(model))"
                default:
                    label = limit.kind
                }
                return UsageWindow(label: label,
                                   usedPercent: limit.percent.clamped(0, 100),
                                   resetsAt: limit.resetsAt, kind: kind,
                                   windowSeconds: kind.defaultSeconds)
            }
        }

        // ── 구형 fallback (five_hour / seven_day / *fable*) ──
        var out: [UsageWindow] = []
        var consumed: Set<String> = []

        func take(_ key: String, label: String, kind: WindowKind) {
            guard let w = response.windows[key] else { return }
            // 0% 미사용 창은 utilization이 없을 수 있음 → 0으로 간주해 그대로 노출.
            let util = w.utilization ?? 0
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
