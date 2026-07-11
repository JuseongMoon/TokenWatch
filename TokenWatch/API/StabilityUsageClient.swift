//
//  StabilityUsageClient.swift
//  TokenWatch
//
//  Stability AI `GET /v1/user/balance` 호출 → 남은 크레딧을 잔액 창으로 반환.
//  인증: API 키 Bearer. 참고: https://platform.stability.ai/docs/api-reference
//

import Foundation

enum StabilityUsageClient {
    static let balanceURL = "https://api.stability.ai/v1/user/balance"

    static func fetch(tokens: OAuthTokens) async throws -> [UsageWindow] {
        var req = URLRequest(url: URL(string: balanceURL)!)
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
            let value = String(format: "%.2f credits", decoded.credits ?? 0)
            return [UsageWindow(label: "Credits", usedPercent: 0, resetsAt: nil,
                                kind: .weekly, style: .balance, valueText: value,
                                balanceRemaining: decoded.credits)]
        } catch {
            throw UsageError.decode(error.localizedDescription)
        }
    }

    private struct Response: Decodable {
        let credits: Double?
    }
}
