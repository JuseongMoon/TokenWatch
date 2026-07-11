//
//  RecraftUsageClient.swift
//  TokenWatch
//
//  Recraft `GET /v1/users/me` 호출 → 남은 크레딧을 잔액 창으로 반환.
//  인증: API 키 Bearer. 참고: https://www.recraft.ai/docs
//

import Foundation

enum RecraftUsageClient {
    static let meURL = "https://external.api.recraft.ai/v1/users/me"

    static func fetch(tokens: OAuthTokens) async throws -> [UsageWindow] {
        var req = URLRequest(url: URL(string: meURL)!)
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
            let value = "\(decoded.credits ?? 0) credits"
            return [UsageWindow(label: "Credits", usedPercent: 0, resetsAt: nil,
                                kind: .weekly, style: .balance, valueText: value,
                                balanceRemaining: decoded.credits.map(Double.init))]
        } catch {
            throw UsageError.decode(error.localizedDescription)
        }
    }

    private struct Response: Decodable {
        let credits: Int?
        let email: String?
        let name: String?
    }
}
