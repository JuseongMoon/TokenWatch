//
//  DeepSeekUsageClient.swift
//  TokenWatch
//
//  DeepSeek `GET /user/balance` 호출 → 남은 API 크레딧 잔액을 잔액 창으로 반환.
//  인증: API 키 Bearer. total_balance는 문자열로 온다.
//

import Foundation

enum DeepSeekUsageClient {
    static let balanceURL = "https://api.deepseek.com/user/balance"

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
            guard let info = decoded.balance_infos?.first else { return [] }
            let value = "\(info.total_balance ?? "0") \(info.currency ?? "")"
                .trimmingCharacters(in: .whitespaces)
            return [UsageWindow(label: "Balance", usedPercent: 0, resetsAt: nil,
                                kind: .weekly, style: .balance, valueText: value)]
        } catch {
            throw UsageError.decode(error.localizedDescription)
        }
    }

    private struct Response: Decodable {
        let is_available: Bool?
        let balance_infos: [BalanceInfo]?
        struct BalanceInfo: Decodable {
            let currency: String?
            let total_balance: String?
        }
    }
}
