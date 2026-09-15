//
//  GrokUsageClient.swift
//  TokenWatch
//
//  Grok(xAI) 주간 사용량 조회: `cli-chat-proxy.grok.com/v1/billing?format=credits` → 사용량 창.
//  (참고: TokenBar `agent_grok.rs` — 해석 규칙과 테스트 픽스처를 그대로 따른다.)
//
//  2026-06부터 Grok 유료 플랜은 모든 제품(Chat·Build·Imagine·API…)이 함께 쓰는 주간 풀 하나다.
//  `creditUsagePercent`가 그 풀이고, `productUsage[]`는 풀을 제품별로 나눈 값일 뿐이라 창 값으로
//  쓰지 않는다 — CLI 제품 행만 읽으면 소진된 풀이 "4% 사용"으로 보인다(TokenBar #240).
//

import Foundation

enum GrokUsageClient {
    static let creditsURL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"

    static func fetch(tokens: OAuthTokens) async throws -> [UsageWindow] {
        try await fetchUsage(tokens: tokens).windows
    }

    /// 사용량 창과 응답에 실린 플랜 라벨(`subscriptionTiers`, 없을 수 있다).
    static func fetchUsage(tokens: OAuthTokens) async throws -> (windows: [UsageWindow], plan: String?) {
        var req = URLRequest(url: URL(string: creditsURL)!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("TokenWatch/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await APISession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        // 401만 인증 실패로 본다. xAI의 403은 한도·권한 거절이라 refresh로 풀리지 않고,
        // 403마다 refresh하면 회전형 refresh token을 폴링마다 소모한다.
        if status == 401 { throw UsageError.unauthorized }
        if status == 429 {
            throw UsageError.rateLimited(parseRetryAfter(http?.value(forHTTPHeaderField: "Retry-After")))
        }
        guard (200..<300).contains(status) else {
            throw UsageError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return try GrokBillingMapper.usage(from: data)
    }
}

// MARK: - 응답 모델

/// `?format=credits` 응답. 금액·기타 필드(onDemandCap, isUnifiedBillingUser…)는 쓰지 않아 받지 않는다.
struct GrokBillingResponse: Decodable {
    let config: Config?
    /// 일부 응답에만 있는 플랜 라벨(예: "X Premium+"). 문자열 배열로 와도 받아 준다.
    let subscriptionTiers: String?

    struct Config: Decodable {
        let currentPeriod: Period?
        let creditUsagePercent: GrokPercentField?
        let productUsage: [ProductUsage]?
        let billingPeriodStart: String?
        let billingPeriodEnd: String?
    }

    struct Period: Decodable {
        /// proto enum 이름(예: `USAGE_PERIOD_TYPE_WEEKLY`).
        let type: String?
        let start: String?
        let end: String?
    }

    struct ProductUsage: Decodable {
        let usagePercent: GrokPercentField?
    }

    private enum CodingKeys: String, CodingKey { case config, subscriptionTiers }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        config = try c.decodeIfPresent(Config.self, forKey: .config)
        // 플랜 라벨은 부가 정보다 — 형식이 달라도 전체 파싱을 실패시키지 않는다.
        if let tier = try? c.decodeIfPresent(String.self, forKey: .subscriptionTiers) {
            subscriptionTiers = tier
        } else if let tiers = try? c.decodeIfPresent([String].self, forKey: .subscriptionTiers) {
            subscriptionTiers = tiers.joined(separator: ", ")
        } else {
            subscriptionTiers = nil
        }
    }
}

/// 퍼센트 필드의 원형. 키가 없거나 `null`이면 옵셔널 자체가 nil(= 생략)이고,
/// 숫자가 아닌 값(문자열·불리언 등)은 "있지만 잘못된 값"으로 남겨 0%로 둔갑되지 않게 한다.
enum GrokPercentField: Decodable, Equatable {
    case number(Double)
    case invalid

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(Double.self) {
            self = .number(value)
        } else {
            self = .invalid
        }
    }
}

// MARK: - 응답 → 창 매핑

enum GrokBillingMapper {
    static let weeklyPeriodType = "USAGE_PERIOD_TYPE_WEEKLY"
    static let weeklyLabel = "Current week"

    /// 원본 응답 바이트 → (창, 플랜). 창이 없으면 빈 배열(호출자가 `UsageError.noWindows`로 처리).
    static func usage(from data: Data) throws -> (windows: [UsageWindow], plan: String?) {
        let decoded: GrokBillingResponse
        do {
            decoded = try JSONDecoder().decode(GrokBillingResponse.self, from: data)
        } catch {
            throw UsageError.decode(error.localizedDescription)
        }
        return try usage(from: decoded)
    }

    static func usage(from response: GrokBillingResponse) throws -> (windows: [UsageWindow], plan: String?) {
        let tier = response.subscriptionTiers?.trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = (tier?.isEmpty == false) ? tier : nil
        guard let config = response.config, let window = try weeklyWindow(config) else {
            return ([], plan)
        }
        return ([window], plan)
    }

    /// 주간 풀 창. 사용률을 확정할 수 없으면 nil(창 없음), 값이 잘못됐으면 오류.
    static func weeklyWindow(_ config: GrokBillingResponse.Config) throws -> UsageWindow? {
        let used: Double
        switch weeklyUsedPercent(config) {
        case .value(let percent):
            used = percent
        case .invalid:
            throw UsageError.decode("invalid Grok weekly usage")
        case .absent:
            // 리셋 직후 xAI는 0인 퍼센트를 생략한다. 스스로 완결된 주간 period가 있을 때만 0%로 읽는다.
            guard selfContainedWeeklyPeriod(config) != nil else { return nil }
            used = 0
        }

        let start = (config.currentPeriod?.start ?? config.billingPeriodStart).flatMap { parseDate($0) }
        let end = (config.currentPeriod?.end ?? config.billingPeriodEnd).flatMap { parseDate($0) }
        var seconds: TimeInterval?
        if let start, let end, end > start {
            seconds = end.timeIntervalSince(start)
        }
        return UsageWindow(label: weeklyLabel, usedPercent: used, resetsAt: end,
                           kind: .weekly, windowSeconds: seconds)
    }

    enum WeeklyPercent: Equatable {
        case value(Double)
        /// 퍼센트 필드가 없다(빈 주일 수 있다).
        case absent
        /// 있지만 쓸 수 없는 값 — 0%로 만들면 안 된다.
        case invalid
    }

    /// `creditUsagePercent`만 창 값이 될 수 있다. 제품 행은 값이 아니라 "빈 주가 아니다"라는 반증으로만 쓴다
    /// (풀은 어느 제품 몫보다 크거나 같으므로, 제품 하나라도 사용량을 보고하면 0%일 수 없다).
    static func weeklyUsedPercent(_ config: GrokBillingResponse.Config) -> WeeklyPercent {
        if let field = config.creditUsagePercent {
            guard let percent = validPercent(field) else { return .invalid }
            return .value(percent)
        }
        let usageSeen = (config.productUsage ?? []).contains { row in
            guard let field = row.usagePercent else { return false }
            return validPercent(field) != 0
        }
        return usageSeen ? .invalid : .absent
    }

    static func validPercent(_ field: GrokPercentField) -> Double? {
        guard case .number(let value) = field, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    /// 타입이 정확히 주간이고, 같은 객체 안의 start < end가 파싱되는 period.
    /// 평면 `billingPeriod*` 값은 빌려오지 않는다 — 부분·비주간 period가 주간 창 행세를 하지 못하게.
    static func selfContainedWeeklyPeriod(_ config: GrokBillingResponse.Config) -> (start: Date, end: Date)? {
        guard let period = config.currentPeriod, period.type == weeklyPeriodType,
              let start = period.start.flatMap({ parseDate($0) }),
              let end = period.end.flatMap({ parseDate($0) }),
              end > start
        else { return nil }
        return (start, end)
    }

    /// RFC 3339 시각. 소수 초 자릿수(마이크로초 포함)와 무관하게 읽는다.
    static func parseDate(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = ISO8601DateFormatter.tokenwatch.date(from: text) { return date }
        if let date = ISO8601DateFormatter.tokenwatchNoFraction.date(from: text) { return date }
        // 포매터가 소수 자릿수를 거부하는 경우: 소수 초를 떼어 파싱한 뒤 다시 더한다.
        guard let dot = text.firstIndex(of: "."),
              let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }),
              let base = ISO8601DateFormatter.tokenwatchNoFraction.date(
                  from: String(text[..<dot]) + String(text[zone...])),
              let fraction = Double("0" + text[dot..<zone])
        else { return nil }
        return base.addingTimeInterval(fraction)
    }
}
