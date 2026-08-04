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
/// - gauge: 사용률(0~100%) 게이지. 채움=사용량(찰수록 소진). 한도가 있는 구독/쿼터형(Claude/Codex 등).
/// - creditGauge: 충전형 잔액 게이지. 채움=남은 잔액(역방향, 가득=여유). 총액(API) 또는
///   관측 최고 잔액(추정)을 분모로 삼는다. usedPercent엔 "진짜 소비율(100−잔액%)"이 들어간다.
/// - balance: 절대 잔액 텍스트(예: "6.50 USD", "1.2M pts"). 총액을 알 수 없어 %를 못 내는 fallback.
enum UsageStyle: Sendable, Hashable {
    case gauge
    case creditGauge
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
    /// balance/creditGauge에서 표시할 절대값 문자열(예: "6.50 USD"). 구독 gauge에선 미사용.
    let valueText: String?
    /// 충전형에서 client가 넣는 raw 남은 잔액(게이지 분자). 구독형 gauge엔 nil.
    let balanceRemaining: Double?
    /// API가 총액을 줄 때만 채운다(OpenRouter/D-ID). nil이면 AgentStore가 관측 최고 잔액(peak)으로 추정.
    let balanceTotal: Double?
    /// creditGauge 총액이 관측 최고 잔액 추정치인지(true) API 실제 총액인지(false). "~approx" 표기용.
    let estimatedTotal: Bool

    init(label: String, usedPercent: Double, resetsAt: Date?, kind: WindowKind,
         windowSeconds: TimeInterval? = nil, style: UsageStyle = .gauge,
         valueText: String? = nil, balanceRemaining: Double? = nil,
         balanceTotal: Double? = nil, estimatedTotal: Bool = false) {
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.kind = kind
        self.windowSeconds = windowSeconds
        self.style = style
        self.valueText = valueText
        self.balanceRemaining = balanceRemaining
        self.balanceTotal = balanceTotal
        self.estimatedTotal = estimatedTotal
    }

    /// 0...100
    var remainingPercent: Double { max(0, 100 - usedPercent) }
    var id: String { label }

    /// 전혀 쓰지 않은(사용률 0%) 게이지 창인지. "미사용 창 숨김" 설정의 판정 기준.
    /// balance(잔액 텍스트)·creditGauge(충전형)는 "0% = 미사용" 개념이 없어 항상 false
    /// — 충전형은 잔액 가득(used 0%)이 정상이므로 숨기면 안 된다.
    var isUnused: Bool { style == .gauge && usedPercent <= 0 }

    /// 게이지처럼 그려지는 창(구독 사용률 gauge + 충전형 creditGauge).
    /// 하트비트 usage 추적·자동새로고침 변화 신호·설정 그래프 피커의 공통 판정 기준.
    var isGaugeLike: Bool { style == .gauge || style == .creditGauge }

    /// balance 창을 충전형 게이지 창으로 승격한 복사본. label/valueText/balance*/resetsAt은
    /// 유지하고 style·usedPercent·estimatedTotal만 교체한다. (AgentStore.promoteCreditWindows용.)
    func promotedToCreditGauge(usedPercent: Double, estimatedTotal: Bool) -> UsageWindow {
        UsageWindow(label: label, usedPercent: usedPercent, resetsAt: resetsAt, kind: kind,
                    windowSeconds: windowSeconds, style: .creditGauge, valueText: valueText,
                    balanceRemaining: balanceRemaining, balanceTotal: balanceTotal,
                    estimatedTotal: estimatedTotal)
    }

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

    /// 업무시간 스케줄을 반영한 "현재 시각" 세로선 위치(0…1).
    /// 스케줄이 비어있거나(nil) 계산 불가면 기존 `elapsedFraction`(균일 흐름)으로 폴백한다.
    /// 업무시간이 아닌 구간에선 값이 고정되어 마커가 멈춘다. (주간 창에만 배선 — 세션은 실시간 유지.)
    func markerFraction(at now: Date = Date(), schedule: WorkHoursSchedule?,
                        calendar: Calendar = .current) -> Double? {
        guard let resetsAt, let windowSeconds, windowSeconds > 0 else { return nil }
        if let schedule, !schedule.isEmpty {
            let start = resetsAt.addingTimeInterval(-windowSeconds)
            if let f = WorkHours.markerFraction(windowStart: start, windowEnd: resetsAt,
                                                now: now, schedule: schedule, calendar: calendar) {
                return f
            }
        }
        return elapsedFraction(at: now)
    }
}

/// 한 에이전트의 사용량 스냅샷 (성공 또는 실패).
struct AgentSnapshot: Sendable {
    var windows: [UsageWindow]
    var planLabel: String?
    var fetchedAt: Date
    var error: String?
    /// error의 기계 판독 사유 — 분석 이벤트(usage_fetch_error)용. 표시에는 쓰지 않는다.
    var errorReason: FetchErrorReason? = nil
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
    /// 추가 크레딧(구독 한도 초과분을 표준 요율로 과금). 활성 시에만 채워진다.
    let extraUsage: ClaudeExtraUsage?

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

        // 추가 크레딧(extra_usage) — 활성 시에만 온다. 창 수집보다 먼저 파싱해 이 키를
        // 제외한다(utilization 필드가 있어 ClaudeWindow로 오인 수집될 수 있음).
        if let key = DynamicKey(stringValue: "extra_usage") {
            self.extraUsage = try? container.decode(ClaudeExtraUsage.self, forKey: key)
        } else {
            self.extraUsage = nil
        }

        // 구형 형식: utilization/resets_at을 가진 최상위 창 키들.
        var result: [String: ClaudeWindow] = [:]
        for key in container.allKeys
        where key.stringValue != "limits" && key.stringValue != "extra_usage" {
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

/// 추가 크레딧(usage credits / extra usage). 구독 포함 사용량 초과분을 표준 요율로
/// 과금하며 계속 쓰게 해주는 기능. 금액은 minor units(센트)로 온다(4000 = $40.00).
/// (참고: TokenBar agent_usage.rs ClaudeExtraUsage)
struct ClaudeExtraUsage: Decodable, Sendable {
    let isEnabled: Bool
    let monthlyLimit: Double?   // 월 지출 한도(센트). 게이지 분모.
    let usedCredits: Double?    // 이번 달 사용한 크레딧(센트).
    let utilization: Double?    // 0~100 used %.
    let currency: String?

    private enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization, currency
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? false
        // 숫자가 문자열로 올 수 있어 방어적으로 파싱(ClaudeWindow.utilization과 동일 방식).
        monthlyLimit = Self.number(c, .monthlyLimit)
        usedCredits = Self.number(c, .usedCredits)
        utilization = Self.number(c, .utilization)
        currency = try? c.decode(String.self, forKey: .currency)
    }

    private static func number(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let d = try? c.decode(Double.self, forKey: key) { return d }
        if let s = try? c.decode(String.self, forKey: key), let d = Double(s) { return d }
        return nil
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
    /// 구독 사용률 창 + (활성 시) 추가 크레딧 창을 합쳐 반환한다.
    static func windows(from response: ClaudeUsageResponse) -> [UsageWindow] {
        var out = baseWindows(from: response)
        if let extra = extraUsageWindow(from: response.extraUsage) {
            out.append(extra)
        }
        return out
    }

    /// 구독 사용률 창(session/weekly). 새 형식(limits 배열)이 있으면 그것으로 매핑하고,
    /// 없으면 구형 키(five_hour / seven_day / *fable*)로 fallback한다.
    private static func baseWindows(from response: ClaudeUsageResponse) -> [UsageWindow] {
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

    /// 추가 크레딧(extra_usage)을 충전형 잔액 창으로 변환한다. 비활성이거나 월 한도가
    /// 없으면 nil(창을 만들지 않는다). balanceTotal(월 한도)을 넘기므로 AgentStore의
    /// promoteCreditWindows가 정확한 역방향 게이지(estimatedTotal=false)로 승격한다.
    private static func extraUsageWindow(from extra: ClaudeExtraUsage?) -> UsageWindow? {
        guard let extra, extra.isEnabled,
              let limitMinor = extra.monthlyLimit, limitMinor > 0 else { return nil }
        // used_credits가 없고 utilization만 오면 한도×사용률로 역산.
        let usedMinor = extra.usedCredits ?? extra.utilization.map { limitMinor * $0 / 100 } ?? 0
        let total = limitMinor / 100
        let remaining = max(0, (limitMinor - usedMinor) / 100)
        let value = formatCurrency(remaining, currency: extra.currency) + " left"
        return UsageWindow(label: "Extra usage", usedPercent: 0, resetsAt: nil,
                           kind: .weekly, style: .balance, valueText: value,
                           balanceRemaining: remaining, balanceTotal: total)
    }

    /// 주 단위 금액을 통화 문자열로. USD(기본)는 `$12.40`, 그 외는 `12.40 EUR`.
    private static func formatCurrency(_ major: Double, currency: String?) -> String {
        let code = (currency ?? "USD").trimmingCharacters(in: .whitespaces).uppercased()
        if code.isEmpty || code == "USD" { return String(format: "$%.2f", major) }
        return String(format: "%.2f %@", major, code)
    }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { min(max(self, lo), hi) }
}
