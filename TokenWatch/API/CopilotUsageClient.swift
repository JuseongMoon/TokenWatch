//
//  CopilotUsageClient.swift
//  TokenWatch
//
//  GitHub Copilot `copilot_internal/user` 호출 → 구독의 쿼터 잔여를 사용량 창으로 반환.
//  게이트/갱신/에러 처리는 ProviderUsage(공통 오케스트레이션)가 담당한다.
//
//  인증: device flow로 얻은 GitHub OAuth 토큰을 `Authorization: token <t>`로 전달.
//  응답의 quota_snapshots(premium_interactions/chat …)를 잔여%로 매핑한다.
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
        do {
            let decoded = try JSONDecoder().decode(CopilotUser.self, from: data)
            return decoded.windows()
        } catch {
            throw UsageError.decode(error.localizedDescription)
        }
    }
}

// MARK: - 응답 모델 + 매핑

private struct CopilotUser: Decodable {
    let copilot_plan: String?
    let quota_reset_date: String?
    let quota_snapshots: [String: Snapshot]?

    struct Snapshot: Decodable {
        let entitlement: Double?
        let remaining: Double?
        let percent_remaining: Double?
        let unlimited: Bool?
    }

    /// premium_interactions를 우선 노출하고, 그 외 제한(chat/completions …)은 뒤에 붙인다.
    /// 무제한(unlimited) 스냅샷은 표시를 생략한다. 리셋은 quota_reset_date(YYYY-MM-DD).
    func windows() -> [UsageWindow] {
        guard let snaps = quota_snapshots else { return [] }
        let resetsAt = quota_reset_date.flatMap { Self.parseResetDate($0) }

        let preferredOrder = ["premium_interactions", "chat", "completions"]
        let labels: [String: String] = [
            "premium_interactions": "Premium requests",
            "chat": "Chat",
            "completions": "Completions",
        ]

        var out: [UsageWindow] = []
        func add(_ key: String) {
            guard let s = snaps[key], s.unlimited != true else { return }
            let percentRemaining: Double
            if let p = s.percent_remaining {
                percentRemaining = p
            } else if let e = s.entitlement, e > 0, let r = s.remaining {
                percentRemaining = r / e * 100
            } else {
                percentRemaining = 100
            }
            let used = min(max(100 - percentRemaining, 0), 100)
            let label = labels[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
            out.append(UsageWindow(label: label, usedPercent: used, resetsAt: resetsAt,
                                   kind: .weekly, windowSeconds: nil))
        }

        for key in preferredOrder { add(key) }
        for key in snaps.keys.sorted() where !preferredOrder.contains(key) { add(key) }
        return out
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
