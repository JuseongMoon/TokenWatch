//
//  CodexUsageClient.swift
//  TokenWatch
//
//  Codex(ChatGPT) `backend-api/wham/usage` 호출 → 사용량 창 반환.
//  (참고: TokenBar agent_usage.rs fetch_codex_inner / codex_windows)
//

import Foundation

enum CodexUsageClient {
    static let usageURL = "https://chatgpt.com/backend-api/wham/usage"

    static func fetch(tokens: OAuthTokens) async throws -> [UsageWindow] {
        var req = URLRequest(url: URL(string: usageURL)!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("TokenWatch/1.0", forHTTPHeaderField: "User-Agent")
        if let accountId = tokens.accountId, !accountId.isEmpty {
            req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: req)
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
            let decoded = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            return decoded.windows()
        } catch {
            throw UsageError.decode(error.localizedDescription)
        }
    }
}

// MARK: - 응답 모델 + 매핑

private struct CodexUsageResponse: Decodable {
    let rate_limit: CodexRateLimit?
    let additional_rate_limits: [CodexAdditionalRateLimit]?

    struct CodexRateLimit: Decodable {
        let primary_window: CodexWindow?
        let secondary_window: CodexWindow?
    }
    struct CodexAdditionalRateLimit: Decodable {
        let limit_name: String?
        let metered_feature: String?
        let rate_limit: CodexRateLimit?
    }
    struct CodexWindow: Decodable {
        let used_percent: Double
        let reset_at: Int?
        let limit_window_seconds: Int?
    }

    /// TokenBar codex_windows 이식: primary→Session, secondary→Weekly(필요 시 스왑),
    /// 추가 한도는 라벨 그대로 append.
    func windows() -> [UsageWindow] {
        var out: [UsageWindow] = []
        var seen: Set<String> = []

        if let rl = rate_limit {
            var primary = rl.primary_window
            var secondary = rl.secondary_window
            // primary가 주간(604800)이고 secondary가 주간이 아니면 스왑.
            if role(primary) == .weekly && role(secondary) != .weekly {
                swap(&primary, &secondary)
            }
            if let w = primary, let win = mapped("Current session", w) { out.append(win); seen.insert(win.label) }
            if let w = secondary, let win = mapped("Current week", w) { out.append(win); seen.insert(win.label) }
        }

        for extra in additional_rate_limits ?? [] {
            guard let w = extra.rate_limit?.primary_window ?? extra.rate_limit?.secondary_window else { continue }
            let label = extra.limit_name ?? extra.metered_feature ?? L10n(lang: currentLang()).codexAdditionalLimit
            guard !seen.contains(label), let win = mapped(label, w) else { continue }
            out.append(win); seen.insert(label)
        }
        return out
    }

    private enum WindowRole { case session, weekly, other }
    private func role(_ w: CodexWindow?) -> WindowRole {
        switch w?.limit_window_seconds {
        case 18_000: return .session
        case 604_800: return .weekly
        default: return .other
        }
    }

    private func mapped(_ label: String, _ w: CodexWindow) -> UsageWindow? {
        let kind: WindowKind = role(w) == .session ? .session : .weekly
        let resetsAt = (w.reset_at.map { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil } ?? nil)
        return UsageWindow(label: label,
                           usedPercent: min(max(w.used_percent, 0), 100),
                           resetsAt: resetsAt,
                           kind: kind)
    }
}
