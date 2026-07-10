//
//  FalUsageClient.swift
//  TokenWatch
//
//  fal.ai `GET /v1/account/billing?expand=credits` 호출 → 남은 크레딧 잔액을 잔액 창으로 반환.
//  인증: Admin API 키를 `Authorization: Key <key>`로 전달(Bearer 아님).
//  참고: https://fal.ai/docs/platform-apis/v1/account/billing
//

import Foundation

enum FalUsageClient {
    static let billingURL = "https://api.fal.ai/v1/account/billing?expand=credits"

    static func fetch(tokens: OAuthTokens) async throws -> [UsageWindow] {
        var req = URLRequest(url: URL(string: billingURL)!)
        req.httpMethod = "GET"
        req.setValue("Key \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("TokenWatch/1.0", forHTTPHeaderField: "User-Agent")

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
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard let c = decoded.credits else { return [] }
            let value = String(format: "%.2f %@", c.current_balance ?? 0, c.currency ?? "")
                .trimmingCharacters(in: .whitespaces)
            return [UsageWindow(label: "Balance", usedPercent: 0, resetsAt: nil,
                                kind: .weekly, style: .balance, valueText: value)]
        } catch {
            throw UsageError.decode(error.localizedDescription)
        }
    }

    private struct Response: Decodable {
        let username: String?
        let credits: Credits?
        struct Credits: Decodable {
            let current_balance: Double?
            let currency: String?
        }
    }
}
