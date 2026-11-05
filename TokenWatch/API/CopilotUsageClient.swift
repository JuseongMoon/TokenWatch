//
//  CopilotUsageClient.swift
//  TokenWatch
//
//  GitHub Copilot `copilot_internal/user` 호출 → 구독의 쿼터 잔여를 사용량 창으로 반환.
//  게이트/갱신/에러 처리는 ProviderUsage(공통 오케스트레이션)가 담당한다.
//
//  인증: device flow로 얻은 GitHub OAuth 토큰을 `Authorization: token <t>`로 전달.
//  유료 계정은 quota_snapshots(premium_interactions/chat …)를, Free 계정은
//  limited_user_quotas(남은 양)/monthly_quotas(월 한도)를 사용률로 매핑한다(`windows(from:)`).
//

import Foundation

enum CopilotUsageClient {
    static let userURL = "https://api.github.com/copilot_internal/user"

    static func fetch(tokens: OAuthTokens) async throws -> [UsageWindow] {
        var req = URLRequest(url: URL(string: userURL)!)
        req.httpMethod = "GET"
        req.setValue("token \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        req.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        req.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        req.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")

        let (data, response) = try await APISession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 || status == 403 { throw UsageError.unauthorized }
        if status == 429 {
            throw UsageError.rateLimited(parseRetryAfter(http?.value(forHTTPHeaderField: "Retry-After")))
        }
        guard (200..<300).contains(status) else {
            throw UsageError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return try windows(from: data)
    }

    /// 응답 본문 → 사용량 창(순수 함수 — 테스트 대상). 레인(쿼터 키)별로 계산한다(Android와 같은 규칙).
    ///
    /// - 순서: premium_interactions → chat → completions → `quota_snapshots`의 그 밖의 키(이름순).
    ///   라벨: "Premium requests" / "Chat" / "Completions" / 그 밖은 키를 단어 대문자화.
    /// - `quota_snapshots` 레인: `percent_remaining` 우선, 없으면 remaining/entitlement×100. 사용률 = 100 − 남은 %(0~100).
    ///   무제한(`unlimited`, entitlement·remaining −1)은 숨기고 Free 값으로도 채우지 않는다.
    ///   entitlement 0·수치 없는 스냅샷은 측정 불가로 보고 그 자체로는 표시하지 않는다.
    /// - Free 값(`limited_user_quotas` 남은 양 ÷ `monthly_quotas` 월 한도)은 chat·completions 레인에만,
    ///   스냅샷에 그 레인이 없거나 측정 불가일 때 쓴다. 한도 ≤ 0이거나 남은 양이 없으면 표시하지 않는다.
    /// - 리셋: `quota_reset_date`, 없으면 `limited_user_reset_date`(YYYY-MM-DD → 로컬 자정).
    /// - 쿼터 정보가 전혀 없는 200(구독 종료 계정 등)은 빈 배열 — 호출자가 "표시할 데이터 없음"(noWindows)으로 처리한다.
    static func windows(from data: Data) throws -> [UsageWindow] {
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UsageError.decode("copilot response is not a JSON object")
        }
        let resetsAt = (body["quota_reset_date"] as? String).flatMap { parseResetDate($0) }
            ?? (body["limited_user_reset_date"] as? String).flatMap { parseResetDate($0) }
        let snaps = body["quota_snapshots"] as? [String: Any] ?? [:]
        let limited = body["limited_user_quotas"] as? [String: Any] ?? [:]
        let monthly = body["monthly_quotas"] as? [String: Any] ?? [:]
        let freeLanes: Set<String> = ["chat", "completions"]

        var keys = ["premium_interactions", "chat", "completions"]
        keys += snaps.keys.filter { !keys.contains($0) }.sorted()

        var out: [UsageWindow] = []
        for key in keys {
            let used: Double?
            switch snapshotLane(snaps[key]) {
            case .unlimited:
                used = nil
            case .measured(let value):
                used = value
            case .unmeasurable:
                used = freeLanes.contains(key) ? freeUsedPercent(remaining: limited[key], total: monthly[key]) : nil
            }
            guard let used else { continue }
            out.append(UsageWindow(label: label(for: key), usedPercent: min(max(used, 0), 100),
                                   resetsAt: resetsAt, kind: .weekly, windowSeconds: nil))
        }
        return out
    }

    private enum SnapshotLane {
        case measured(Double)   // 사용률(자르기 전)
        case unlimited          // 숨김, Free로도 채우지 않음
        case unmeasurable       // 레인 없음·수치 없음·entitlement 0 — Free 레인이면 Free 값으로 채울 수 있다
    }

    private static func snapshotLane(_ raw: Any?) -> SnapshotLane {
        guard let snap = raw as? [String: Any] else { return .unmeasurable }
        let entitlement = number(snap["entitlement"])
        let remaining = number(snap["remaining"])
        if (snap["unlimited"] as? Bool) == true || entitlement == -1 || remaining == -1 { return .unlimited }
        if entitlement == 0 { return .unmeasurable }
        if let percentRemaining = number(snap["percent_remaining"]) { return .measured(100 - percentRemaining) }
        if let entitlement, entitlement > 0, let remaining { return .measured(100 - remaining / entitlement * 100) }
        return .unmeasurable
    }

    /// Free 레인 사용률 = 100 − 남은 양 ÷ 월 한도 × 100. 한도 ≤ 0이거나 남은 양이 없으면 nil.
    private static func freeUsedPercent(remaining: Any?, total: Any?) -> Double? {
        guard let total = number(total), total > 0, let remaining = number(remaining) else { return nil }
        return 100 - remaining / total * 100
    }

    /// 표시 라벨(Android와 같은 문자열).
    static func label(for key: String) -> String {
        switch key {
        case "premium_interactions": return "Premium requests"
        case "chat": return "Chat"
        case "completions": return "Completions"
        default: return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// JSON 숫자 또는 숫자 문자열(GitHub가 월 한도를 문자열로 줄 때가 있다). 불리언·비유한 값은 nil.
    private static func number(_ raw: Any?) -> Double? {
        if let n = raw as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        if let text = raw as? String, let value = Double(text.trimmingCharacters(in: .whitespaces)),
           value.isFinite {
            return value
        }
        return nil
    }

    /// "YYYY-MM-DD"(날짜만) → 그 날 기기 로컬 자정 Date.
    /// UTC 자정으로 앵커링하면 UTC 서쪽 타임존에서 전날로 표시되고 알림도 어긋난다 —
    /// 캘린더 날짜는 로컬 자정이 맞다.
    private static func parseResetDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
}
