//
//  DIDUsageClient.swift
//  TokenWatch
//
//  D-ID `GET /credits` 호출 → 남은 크레딧을 잔액 창으로 반환.
//  인증: API 키를 `Authorization: Basic <key>`로 전달(base64 형태의 키 그대로).
//  응답 최상위 remaining/total, 없으면 credits[0]에서 폴백.
//

import Foundation

enum DIDUsageClient {
    static let creditsURL = "https://api.d-id.com/credits"

    static func fetch(tokens: OAuthTokens) async throws -> [UsageWindow] {
        var req = URLRequest(url: URL(string: creditsURL)!)
        req.httpMethod = "GET"
        req.setValue("Basic \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
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
            let remaining = decoded.remaining ?? decoded.credits?.first?.remaining ?? 0
            let value = "\(Int(remaining.rounded())) credits"
            return [UsageWindow(label: "Credits", usedPercent: 0, resetsAt: nil,
                                kind: .weekly, style: .balance, valueText: value)]
        } catch {
            throw UsageError.decode(error.localizedDescription)
        }
    }

    private struct Response: Decodable {
        let remaining: Double?
        let total: Double?
        let credits: [Item]?
        struct Item: Decodable {
            let remaining: Double?
            let total: Double?
        }
    }
}
