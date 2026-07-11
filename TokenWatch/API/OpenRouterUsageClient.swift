//
//  OpenRouterUsageClient.swift
//  TokenWatch
//
//  OpenRouter `GET /api/v1/credits` 호출 → 남은 크레딧 잔액을 잔액 창으로 반환.
//  인증: API 키 Bearer. 참고: https://openrouter.ai/docs/api/reference/limits
//

import Foundation

enum OpenRouterUsageClient {
    static let creditsURL = "https://openrouter.ai/api/v1/credits"

    static func fetch(tokens: OAuthTokens) async throws -> [UsageWindow] {
        var req = URLRequest(url: URL(string: creditsURL)!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
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
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let total = decoded.data?.total_credits ?? 0
            let remaining = total - (decoded.data?.total_usage ?? 0)
            let value = String(format: "%.2f credits left", max(remaining, 0))
            return [UsageWindow(label: "Credits", usedPercent: 0, resetsAt: nil,
                                kind: .weekly, style: .balance, valueText: value,
                                balanceRemaining: max(remaining, 0), balanceTotal: total)]
        } catch {
            throw UsageError.decode(error.localizedDescription)
        }
    }

    private struct Response: Decodable {
        let data: Credits?
        struct Credits: Decodable {
            let total_credits: Double?
            let total_usage: Double?
        }
    }
}
