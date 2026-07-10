//
//  LeonardoUsageClient.swift
//  TokenWatch
//
//  Leonardo `GET /api/rest/v1/me` 호출 → 남은 API 토큰을 잔액 창으로 반환.
//  인증: API 키 Bearer. 응답은 user_details 배열에 토큰 필드가 중첩된다.
//  ⚠️ 토큰 필드명(apiSubscriptionTokens/apiPaidTokens)은 검증 대상.
//

import Foundation

enum LeonardoUsageClient {
    static let meURL = "https://cloud.leonardo.ai/api/rest/v1/me"

    static func fetch(tokens: OAuthTokens) async throws -> [UsageWindow] {
        var req = URLRequest(url: URL(string: meURL)!)
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
            guard let d = decoded.user_details?.first else { return [] }
            // API 토큰(구독+선불) 합산, 없으면 웹 구독 토큰으로 폴백.
            let apiTokens = (d.apiSubscriptionTokens ?? 0) + (d.apiPaidTokens ?? 0)
            let tokensLeft = apiTokens > 0 ? apiTokens : (d.subscriptionTokens ?? 0)
            let value = "\(tokensLeft) tokens"
            return [UsageWindow(label: "API tokens", usedPercent: 0, resetsAt: nil,
                                kind: .weekly, style: .balance, valueText: value)]
        } catch {
            throw UsageError.decode(error.localizedDescription)
        }
    }

    private struct Response: Decodable {
        let user_details: [Detail]?
        struct Detail: Decodable {
            let subscriptionTokens: Int?
            let apiSubscriptionTokens: Int?
            let apiPaidTokens: Int?
        }
    }
}
