//
//  CursorUsageClient.swift
//  TokenWatch
//
//  Cursor `api/usage?user=<id>` 호출 → 구독의 빠른(프리미엄) 요청 사용량을 창으로 반환.
//  게이트/갱신/에러 처리는 ProviderUsage(공통 오케스트레이션)가 담당한다.
//
//  인증: 캡처한 WorkosCursorSessionToken 쿠키를 Cookie 헤더로 전달.
//  ⚠️ 내부(리버스 엔지니어링) 엔드포인트라 응답 구조가 바뀔 수 있다 → 방어적으로 디코딩.
//

import Foundation

enum CursorUsageClient {
    static let usageURL = "https://cursor.com/api/usage"

    static func fetch(tokens: OAuthTokens) async throws -> [UsageWindow] {
        guard let userId = tokens.accountId, !userId.isEmpty else {
            // user_id 없이는 usage?user= 호출 불가 → 재로그인 유도.
            throw UsageError.unauthorized
        }
        var comp = URLComponents(string: usageURL)!
        comp.queryItems = [URLQueryItem(name: "user", value: userId)]

        var req = URLRequest(url: comp.url!)
        req.httpMethod = "GET"
        req.setValue("\(CursorAuth.cookieName)=\(tokens.accessToken)", forHTTPHeaderField: "Cookie")
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
            let decoded = try JSONDecoder().decode(CursorUsage.self, from: data)
            return decoded.windows()
        } catch {
            throw UsageError.decode(error.localizedDescription)
        }
    }
}

// MARK: - 응답 모델 + 매핑

/// 응답 형태: 최상위에 모델별 버킷(`gpt-4`, `gpt-3.5-turbo` …)과 `startOfMonth`.
/// 예) { "gpt-4": {"numRequests":100,"maxRequestUsage":500}, "startOfMonth": "2026-07-01T..." }
private struct CursorUsage: Decodable {
    let buckets: [String: Bucket]
    let startOfMonth: String?

    struct Bucket: Decodable {
        let numRequests: Int?
        let maxRequestUsage: Int?
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var found: [String: Bucket] = [:]
        var start: String?
        for key in container.allKeys {
            if key.stringValue == "startOfMonth" {
                start = try? container.decode(String.self, forKey: key)
            } else if let b = try? container.decode(Bucket.self, forKey: key),
                      b.numRequests != nil || b.maxRequestUsage != nil {
                found[key.stringValue] = b
            }
        }
        self.buckets = found
        self.startOfMonth = start
    }

    /// gpt-4(빠른 요청)를 우선 노출한다. 없으면 한도(maxRequestUsage>0)가 있는 첫 버킷.
    func windows() -> [UsageWindow] {
        let bucket = buckets["gpt-4"] ?? buckets.values.first { ($0.maxRequestUsage ?? 0) > 0 }
        guard let b = bucket, let max = b.maxRequestUsage, max > 0 else { return [] }
        let used = Double(b.numRequests ?? 0)
        let usedPercent = min(Swift.max(used / Double(max) * 100, 0), 100)

        // startOfMonth + 1개월 = 다음 리셋. 파싱 실패 시 리셋 미표기.
        let resetsAt: Date? = startOfMonth.flatMap {
            let d = ISO8601DateFormatter.tokenwatch.date(from: $0)
                ?? ISO8601DateFormatter.tokenwatchNoFraction.date(from: $0)
            return d.flatMap { Calendar.current.date(byAdding: .month, value: 1, to: $0) }
        }

        return [
            UsageWindow(label: "Fast requests",
                        usedPercent: usedPercent,
                        resetsAt: resetsAt,
                        kind: .weekly,
                        windowSeconds: nil)
        ]
    }
}
