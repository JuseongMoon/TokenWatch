//
//  HeyGenUsageClient.swift
//  TokenWatch
//
//  HeyGen `GET /v2/user/remaining_quota` 호출 → 남은 크레딧을 잔액 창으로 반환.
//  인증: API 키를 `X-Api-Key` 헤더로 전달. 응답은 { data: { remaining_quota }, error }.
//  ⚠️ remaining_quota 단위는 검증 대상(관례상 /60 = 크레딧).
//

import Foundation

enum HeyGenUsageClient {
    static let quotaURL = "https://api.heygen.com/v2/user/remaining_quota"

    static func fetch(tokens: OAuthTokens) async throws -> [UsageWindow] {
        var req = URLRequest(url: URL(string: quotaURL)!)
        req.httpMethod = "GET"
        req.setValue(tokens.accessToken, forHTTPHeaderField: "X-Api-Key")
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
            guard let quota = decoded.data?.remaining_quota else { return [] }
            let credits = quota / 60.0
            let value = String(format: "%.0f credits", credits)
            return [UsageWindow(label: "Credits", usedPercent: 0, resetsAt: nil,
                                kind: .weekly, style: .balance, valueText: value,
                                balanceRemaining: credits)]
        } catch {
            throw UsageError.decode(error.localizedDescription)
        }
    }

    private struct Response: Decodable {
        let data: Data0?
        struct Data0: Decodable {
            let remaining_quota: Double?
        }
    }
}
