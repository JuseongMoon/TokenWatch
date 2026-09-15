//
//  KimiUsageClient.swift
//  TokenWatch
//
//  Kimi Code 구독 사용량: `GET https://api.kimi.com/coding/v1/usages`(글로벌 계정은 api.kimi.ai) → 사용량 창.
//  공식 kimi-code CLI(`packages/oauth/src/managed-usage.ts`)가 부르는 주소·헤더를 그대로 쓴다.
//
//  자격증명은 사용자가 Kimi Code 콘솔에서 만든 API 키(`sk-kimi-…`)다. 공식 CLI 로그인(device flow)은
//  CLI 식별 헤더를 흉내 내야 해서 쓰지 않는다(커뮤니티 가이드라인: 클라이언트 식별 정보 위조 금지).
//
//  ⚠️ 공개 문서가 없는 엔드포인트이고 응답 형식이 바뀌는 중이다(2026-09-15 공식 CLI가 신형 파서 추가).
//     신형(`usages.limit_5h|limit_7d|limit_month_total|limit_month_code`의 `used_ratio`)을 먼저 보고,
//     창이 안 나오면 구형(`usage` = 주간, `limits[]`의 300분 창 = 5시간)을 읽는다.
//

import Foundation

enum KimiUsageClient {
    /// 키가 통하는지 순서대로 확인할 API 호스트(중국 기본 → 글로벌). 공식 CLI의 두 기본값과 같다.
    static let hosts = ["api.kimi.com", "api.kimi.ai"]

    static func usagesURL(host: String) -> URL { URL(string: "https://\(host)/coding/v1/usages")! }
    static func meURL(host: String) -> URL { URL(string: "https://\(host)/coding/v1/me")! }

    // MARK: 키 추가

    /// 키를 추가하기 전에 통하는 호스트를 찾고(401만 다음 호스트로 넘어간다), 플랜 이름을 붙여 자격증명을 만든다.
    /// 두 호스트가 모두 거부하면 카드를 만들지 않도록 throw한다.
    static func prepareCredential(apiKey: String) async throws -> OAuthTokens {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        for host in hosts {
            do {
                _ = try await fetchUsagesData(key: key, host: host)
            } catch UsageError.unauthorized {
                continue
            }
            // 플랜 이름은 표시용 부가 정보라 실패해도 추가는 진행한다.
            let plan = try? await fetchPlanName(key: key, host: host)
            return OAuthTokens.apiKey(key, plan: plan, accountId: host)
        }
        throw KimiKeyError.invalid
    }

    // MARK: 사용량

    static func fetch(tokens: OAuthTokens) async throws -> [UsageWindow] {
        let host = tokens.accountId.flatMap { hosts.contains($0) ? $0 : nil } ?? hosts[0]
        let data = try await fetchUsagesData(key: tokens.accessToken, host: host)
        return try KimiUsageMapper.windows(from: data)
    }

    /// `/usages` 원본 응답. 401 → unauthorized(키 무효), 403·404 → http 오류(100%로 보이지 않게), 429 → rateLimited.
    static func fetchUsagesData(key: String, host: String) async throws -> Data {
        var req = URLRequest(url: usagesURL(host: host))
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("TokenWatch/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await APISession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 { throw UsageError.unauthorized }
        if status == 429 {
            throw UsageError.rateLimited(parseRetryAfter(http?.value(forHTTPHeaderField: "Retry-After")))
        }
        guard (200..<300).contains(status) else {
            throw UsageError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// 플랜 이름(`/coding/v1/me`의 `user_level_name`). 응답에 이메일·전화번호도 있어 이 필드만 읽는다.
    static func fetchPlanName(key: String, host: String) async throws -> String? {
        var req = URLRequest(url: meURL(host: host))
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("TokenWatch/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await APISession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return KimiUsageMapper.planName(from: data)
    }
}

enum KimiKeyError: LocalizedError {
    /// 두 지역 호스트 모두 키를 거부했다.
    case invalid

    var errorDescription: String? {
        L10n(lang: currentLang()).errInvalidAPIKey
    }
}

// MARK: - 응답 → 창 매핑

enum KimiUsageMapper {
    static let sessionLabel = "Current session"
    static let weeklyLabel = "Current week"
    static let monthlyLabel = "Current month"
    static let monthlyCodeLabel = "Current month (Code)"

    /// 신형을 먼저 보고, 창이 하나도 안 나오면 구형을 읽는다. 둘 다 없으면 빈 배열(호출자가 noWindows로 처리).
    static func windows(from data: Data) throws -> [UsageWindow] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.decode("Kimi usages is not a JSON object")
        }
        let modern = modernWindows(json["usages"])
        return modern.isEmpty ? legacyWindows(json) : modern
    }

    /// 신형: `usages.{limit_5h, limit_7d, limit_month_total, limit_month_code}.{used_ratio, reset_time}`.
    /// 공식 파서처럼 비율이 수가 아닌 항목은 건너뛴다.
    static func modernWindows(_ raw: Any?) -> [UsageWindow] {
        guard let usages = raw as? [String: Any] else { return [] }
        let specs: [(key: String, label: String, kind: WindowKind, seconds: TimeInterval?)] = [
            ("limit_5h", sessionLabel, .session, 5 * 3600),
            ("limit_7d", weeklyLabel, .weekly, 7 * 24 * 3600),
            ("limit_month_total", monthlyLabel, .weekly, nil),
            ("limit_month_code", monthlyCodeLabel, .weekly, nil),
        ]
        return specs.compactMap { spec in
            guard let entry = usages[spec.key] as? [String: Any],
                  let ratio = number(entry["used_ratio"])
            else { return nil }
            let resetsAt = (entry["reset_time"] as? String).flatMap { ISO8601DateFormatter.tokenwatchDate(from: $0) }
            return UsageWindow(label: spec.label, usedPercent: clampPercent(ratio * 100),
                               resetsAt: resetsAt, kind: spec.kind, windowSeconds: spec.seconds)
        }
    }

    /// 구형: `limits[].window{duration,timeUnit}`가 300분인 항목 = 5시간, `usage{limit,used?,remaining,resetTime}` = 주간.
    static func legacyWindows(_ json: [String: Any]) -> [UsageWindow] {
        var out: [UsageWindow] = []
        for item in json["limits"] as? [[String: Any]] ?? [] {
            guard let window = item["window"] as? [String: Any],
                  let seconds = windowSeconds(window), seconds == 5 * 3600,
                  let detail = item["detail"] as? [String: Any],
                  let session = legacyWindow(detail, label: sessionLabel, kind: .session, seconds: seconds)
            else { continue }
            out.append(session)
            break
        }
        if let usage = json["usage"] as? [String: Any],
           let weekly = legacyWindow(usage, label: weeklyLabel, kind: .weekly, seconds: 7 * 24 * 3600) {
            out.append(weekly)
        }
        return out
    }

    /// 수는 문자열(`"100"`)로 온다. `used`가 없으면 `limit − remaining`.
    static func legacyWindow(_ entry: [String: Any], label: String, kind: WindowKind,
                             seconds: TimeInterval) -> UsageWindow? {
        guard let limit = number(entry["limit"]), limit > 0 else { return nil }
        let used: Double
        if let value = number(entry["used"]) {
            used = value
        } else if let remaining = number(entry["remaining"]) {
            used = limit - remaining
        } else {
            return nil
        }
        let resetsAt = (entry["resetTime"] as? String).flatMap { ISO8601DateFormatter.tokenwatchDate(from: $0) }
        return UsageWindow(label: label, usedPercent: clampPercent(used / limit * 100),
                           resetsAt: resetsAt, kind: kind, windowSeconds: seconds)
    }

    /// `window{duration, timeUnit}` → 초. 모르는 단위면 nil.
    static func windowSeconds(_ window: [String: Any]) -> TimeInterval? {
        guard let duration = number(window["duration"]) else { return nil }
        switch window["timeUnit"] as? String {
        case "TIME_UNIT_SECOND": return duration
        case "TIME_UNIT_MINUTE": return duration * 60
        case "TIME_UNIT_HOUR": return duration * 3600
        case "TIME_UNIT_DAY": return duration * 86_400
        default: return nil
        }
    }

    /// 숫자 또는 숫자 문자열 → Double. 불리언·유한하지 않은 값은 nil.
    static func number(_ value: Any?) -> Double? {
        let parsed: Double?
        if let n = value as? NSNumber {
            // JSONSerialization은 true/false도 NSNumber로 준다 — 수로 읽지 않는다.
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            parsed = n.doubleValue
        } else if let text = value as? String {
            parsed = Double(text.trimmingCharacters(in: .whitespaces))
        } else {
            parsed = nil
        }
        guard let parsed, parsed.isFinite else { return nil }
        return parsed
    }

    static func clampPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }

    /// `/me` 응답에서 플랜 이름만 꺼낸다(빈 문자열이면 nil).
    static func planName(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = (json["user_level_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return nil }
        return name
    }
}
