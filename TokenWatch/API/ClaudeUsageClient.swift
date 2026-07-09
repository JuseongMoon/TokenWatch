//
//  ClaudeUsageClient.swift
//  TokenWatch
//
//  Claude `/api/oauth/usage` 호출 → 사용량 창 반환.
//  게이트/갱신/에러 처리는 ProviderUsage(공통 오케스트레이션)가 담당한다.
//  (참고: TokenBar agent_usage.rs fetch_claude_oauth_usage)
//

import Foundation

enum ClaudeUsageClient {
    static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    static let betaHeader = "oauth-2025-04-20"

    static func fetch(tokens: OAuthTokens) async throws -> [UsageWindow] {
        var req = URLRequest(url: URL(string: usageURL)!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue("TokenWatch/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 { throw UsageError.unauthorized }
        if status == 429 {
            throw UsageError.rateLimited(parseRetryAfter(http?.value(forHTTPHeaderField: "Retry-After")))
        }
        guard (200..<300).contains(status) else {
            throw UsageError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            let decoded = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
            return ClaudeUsageMapper.windows(from: decoded)
        } catch {
            throw UsageError.decode(error.localizedDescription)
        }
    }
}
