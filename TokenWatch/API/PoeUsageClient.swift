//
//  PoeUsageClient.swift
//  TokenWatch
//
//  Poe `GET /usage/current_balance` 호출 → 남은 컴퓨트 포인트를 잔액 창으로 반환.
//  Poe 포인트는 구독에 연동돼 개발자 API가 아닌 구독 잔여를 반영한다(드문 케이스).
//  인증: API 키 Bearer. 참고: https://creator.poe.com/docs/resources/usage-api
//

import Foundation

enum PoeUsageClient {
    static let balanceURL = "https://api.poe.com/usage/current_balance"

    static func fetch(tokens: OAuthTokens) async throws -> [UsageWindow] {
        var req = URLRequest(url: URL(string: balanceURL)!)
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
            let points = decoded.current_point_balance ?? 0
            let value = "\(Self.grouped(points)) pts"
            return [UsageWindow(label: "Compute points", usedPercent: 0, resetsAt: nil,
                                kind: .weekly, style: .balance, valueText: value)]
        } catch {
            throw UsageError.decode(error.localizedDescription)
        }
    }

    private struct Response: Decodable {
        let current_point_balance: Int?
    }

    /// 1250000 → "1,250,000" (천 단위 구분).
    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
