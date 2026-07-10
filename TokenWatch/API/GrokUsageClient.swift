//
//  GrokUsageClient.swift
//  TokenWatch
//
//  Grok `POST GrokBuildBilling/GetGrokCreditsConfig` (gRPC-web) 호출 →
//  구독 크레딧 사용률/리셋을 사용량 창으로 반환.
//  인증: 캡처한 grok.com 쿠키 전체를 Cookie 헤더로 전달.
//
//  ⚠️ 응답이 protobuf(gRPC-web)이고 .proto 스키마가 없어, 숫자 leaf를 수집해
//     휴리스틱으로 usedPercent/reset을 고른다. 필드 매핑은 실제 세션 응답으로
//     확정해야 하는 검증 대상이다. (누락/불일치 시 빈 창 — 크래시 없음.)
//

import Foundation

enum GrokUsageClient {
    static let creditsURL = "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"

    static func fetch(tokens: OAuthTokens) async throws -> [UsageWindow] {
        var req = URLRequest(url: URL(string: creditsURL)!)
        req.httpMethod = "POST"
        req.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        req.setValue("application/grpc-web+proto", forHTTPHeaderField: "Accept")
        req.setValue(tokens.accessToken, forHTTPHeaderField: "Cookie")   // 캡처한 쿠키 전체
        req.setValue("TokenWatch/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("1", forHTTPHeaderField: "x-grpc-web")
        // gRPC-web 빈 메시지 프레임: [압축 플래그 0][길이 0].
        req.httpBody = Data([0, 0, 0, 0, 0])

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
        // gRPC-web 상태를 헤더로도 줄 수 있음(grpc-status != 0 이면 인증 실패 등).
        if let gs = http?.value(forHTTPHeaderField: "grpc-status"), gs != "0", gs != "" {
            throw UsageError.unauthorized
        }

        guard let message = Protobuf.grpcWebMessage(data) else { return [] }
        return Self.map(message)
    }

    /// 스키마 없이 숫자 leaf에서 usedPercent/reset을 추정한다(검증 대상).
    static func map(_ message: Data) -> [UsageWindow] {
        let (doubles, varints) = Protobuf.collectNumbers(message)

        // usedPercent: 0~100 범위의 double(우선), 없으면 같은 범위의 varint.
        let percentD = doubles.first { $0 >= 0 && $0 <= 100 }
        let percentV = varints.first { $0 <= 100 }.map(Double.init)
        guard let used = percentD ?? percentV else { return [] }

        // reset: 유닉스 타임스탬프로 보이는 varint(초 또는 밀리초).
        let resetsAt: Date? = varints
            .map { v -> Date? in
                if v >= 1_500_000_000 && v <= 4_100_000_000 {          // 초
                    return Date(timeIntervalSince1970: TimeInterval(v))
                }
                if v >= 1_500_000_000_000 && v <= 4_100_000_000_000 {  // 밀리초
                    return Date(timeIntervalSince1970: TimeInterval(v) / 1000)
                }
                return nil
            }
            .compactMap { $0 }
            .first

        return [UsageWindow(label: "Credits",
                            usedPercent: min(max(used, 0), 100),
                            resetsAt: resetsAt,
                            kind: .weekly,
                            windowSeconds: nil)]
    }
}
