//
//  LumaUsageClient.swift
//  TokenWatch
//
//  Luma(Dream Machine) `GET /dream-machine/v1/credits` 호출 → 남은 크레딧 잔액을 잔액 창으로.
//  인증: API 키 Bearer. credit_balance는 USD 센트 단위(→ /100 = USD).
//  ⚠️ credit_balance 단위는 검증 대상(문서상 센트).
//

import Foundation

enum LumaUsageClient {
    static let creditsURL = "https://api.lumalabs.ai/dream-machine/v1/credits"

    static func fetch(tokens: OAuthTokens) async throws -> [UsageWindow] {
        var req = URLRequest(url: URL(string: creditsURL)!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
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
            let usd = (decoded.credit_balance ?? 0) / 100.0
            let value = String(format: "%.2f USD", usd)
            return [UsageWindow(label: "Balance", usedPercent: 0, resetsAt: nil,
                                kind: .weekly, style: .balance, valueText: value)]
        } catch {
            throw UsageError.decode(error.localizedDescription)
        }
    }

    private struct Response: Decodable {
        let credit_balance: Double?
    }
}
