//
//  WindsurfUsageClient.swift
//  TokenWatch
//
//  Windsurf `POST SeatManagementService/GetPlanStatus` (ConnectRPC, JSON 코덱) 호출 →
//  구독의 일/주 쿼터 잔여를 사용량 창으로 반환.
//  인증: 캡처한 localStorage 토큰들을 x-auth-token / x-devin-* 헤더로 전달.
//
//  ⚠️ 응답 필드명(camelCase vs snake_case)이 불확실해 두 표기를 모두 시도한다(검증 대상).
//

import Foundation

enum WindsurfUsageClient {
    static let url = "https://windsurf.com/_backend/exa.seat_management_pb.SeatManagementService/GetPlanStatus"

    static func fetch(tokens: OAuthTokens) async throws -> [UsageWindow] {
        // accessToken엔 헤더 dict가 JSON으로 패킹돼 있다.
        let headers = ((try? JSONSerialization.jsonObject(with: Data(tokens.accessToken.utf8)))
                       as? [String: String]) ?? [:]

        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue("TokenWatch/1.0", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = Data("{}".utf8)

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
        return Self.map(data)
    }

    /// Connect JSON 응답에서 일/주 잔여 퍼센트를 게이지 창으로 매핑한다.
    static func map(_ data: Data) -> [UsageWindow] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }

        func number(_ keys: [String]) -> Double? {
            for k in keys {
                if let n = obj[k] as? Double { return n }
                if let n = obj[k] as? Int { return Double(n) }
                if let s = obj[k] as? String, let d = Double(s) { return d }
            }
            return nil
        }

        var out: [UsageWindow] = []
        if let daily = number(["dailyQuotaRemainingPercent", "daily_quota_remaining_percent"]) {
            out.append(UsageWindow(label: "Daily quota",
                                   usedPercent: min(max(100 - daily, 0), 100),
                                   resetsAt: nil, kind: .session))
        }
        if let weekly = number(["weeklyQuotaRemainingPercent", "weekly_quota_remaining_percent"]) {
            out.append(UsageWindow(label: "Weekly quota",
                                   usedPercent: min(max(100 - weekly, 0), 100),
                                   resetsAt: nil, kind: .weekly))
        }
        return out
    }
}
