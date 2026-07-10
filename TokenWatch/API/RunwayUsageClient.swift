//
//  RunwayUsageClient.swift
//  TokenWatch
//
//  Runway `GET /v1/organization` 호출 → 남은 크레딧 잔액을 잔액 창으로 반환.
//  인증: API 키(`key_`로 시작) Bearer + 필수 헤더 `X-Runway-Version`.
//  ⚠️ 웹앱 구독 크레딧과 API 크레딧은 분리(개발자 API 잔액만 보임).
//

import Foundation

enum RunwayUsageClient {
    static let organizationURL = "https://api.dev.runwayml.com/v1/organization"
    static let apiVersion = "2024-11-06"

    static func fetch(tokens: OAuthTokens) async throws -> [UsageWindow] {
        var req = URLRequest(url: URL(string: organizationURL)!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(apiVersion, forHTTPHeaderField: "X-Runway-Version")
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
            let value = "\(Int((decoded.creditBalance ?? 0).rounded())) credits"
            return [UsageWindow(label: "Credits", usedPercent: 0, resetsAt: nil,
                                kind: .weekly, style: .balance, valueText: value)]
        } catch {
            throw UsageError.decode(error.localizedDescription)
        }
    }

    private struct Response: Decodable {
        let creditBalance: Double?
    }
}
