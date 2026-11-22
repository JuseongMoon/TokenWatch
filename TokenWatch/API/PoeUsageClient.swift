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

        let (data, response) = try await APISession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        if let error = statusError(http?.statusCode ?? 0,
                                   retryAfter: http?.value(forHTTPHeaderField: "Retry-After"), body: data) {
            throw error
        }
        do {
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let points = decoded.current_point_balance ?? 0
            let value = "\(Self.grouped(points)) pts"
            return [UsageWindow(label: "Compute points", usedPercent: 0, resetsAt: nil,
                                kind: .weekly, style: .balance, valueText: value,
                                balanceRemaining: Double(points))]
        } catch {
            throw UsageError.decode(error.localizedDescription)
        }
    }

    /// 비정상 상태 코드 → 오류(순수 함수 — 테스트 대상). 2xx면 nil.
    /// 401만 키 거부 안내로 바꾼다 — Usage API 문서에서 401이 "Missing or invalid API Key"(`invalid_api_key`)다.
    /// 403은 문서상 권한·인가 문제라 키 무효로 보지 않고 기존 처리(`unauthorized`) 그대로 둔다.
    static func statusError(_ status: Int, retryAfter: String?, body: Data) -> UsageError? {
        switch status {
        case 200..<300: return nil
        case 401: return .apiKeyRejected(.poe)
        case 403: return .unauthorized
        case 429: return .rateLimited(parseRetryAfter(retryAfter))
        default: return .http(status, String(data: body, encoding: .utf8) ?? "")
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
