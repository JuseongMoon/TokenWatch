//
//  ElevenLabsUsageClient.swift
//  TokenWatch
//
//  ElevenLabs `/v1/user/subscription` 호출 → 남은 문자 할당량을 사용량 창으로 반환.
//  게이트/갱신/에러 처리는 ProviderUsage(공통 오케스트레이션)가 담당한다.
//
//  인증: 사용자가 발급한 API 키를 `xi-api-key` 헤더로 전달(자격증명의 accessToken).
//  참고: https://elevenlabs.io/docs/api-reference/user/subscription/get
//

import Foundation

enum ElevenLabsUsageClient {
    static let subscriptionURL = "https://api.elevenlabs.io/v1/user/subscription"

    static func fetch(tokens: OAuthTokens) async throws -> [UsageWindow] {
        var req = URLRequest(url: URL(string: subscriptionURL)!)
        req.httpMethod = "GET"
        req.setValue(tokens.accessToken, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("TokenWatch/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await APISession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        if let error = statusError(http?.statusCode ?? 0,
                                   retryAfter: http?.value(forHTTPHeaderField: "Retry-After"), body: data) {
            throw error
        }
        do {
            let decoded = try JSONDecoder().decode(ElevenLabsSubscription.self, from: data)
            return decoded.windows()
        } catch {
            throw UsageError.decode(error.localizedDescription)
        }
    }

    /// 비정상 상태 코드 → 오류(순수 함수 — 테스트 대상). 2xx면 nil.
    /// 401(잘못된/누락된 API 키, 본문 `invalid_api_key`)만 키 거부 안내로 바꾼다.
    /// 403(키의 IP 허용 목록 밖)은 키 무효가 아니라 기존처럼 HTTP 오류로 둔다.
    static func statusError(_ status: Int, retryAfter: String?, body: Data) -> UsageError? {
        switch status {
        case 200..<300: return nil
        case 401: return .apiKeyRejected(.elevenlabs)
        case 429: return .rateLimited(parseRetryAfter(retryAfter))
        default: return .http(status, String(data: body, encoding: .utf8) ?? "")
        }
    }
}

// MARK: - 응답 모델 + 매핑

private struct ElevenLabsSubscription: Decodable {
    let character_count: Int?
    let character_limit: Int?
    let next_character_count_reset_unix: Int?
    let tier: String?
    let status: String?

    /// 문자 할당량을 사용량 창 하나로 매핑한다.
    /// (월 단위 리셋이라 창 주기 시작을 알 수 없어 windowSeconds는 nil — 경과 마커 없이
    ///  잔여%·리셋까지 남은 시간만 표기. 남은 시간 표기는 .weekly가 일/시간 단위로 처리.)
    func windows() -> [UsageWindow] {
        let used = Double(character_count ?? 0)
        let limit = Double(character_limit ?? 0)
        let usedPercent = limit > 0 ? min(max(used / limit * 100, 0), 100) : 0
        let resetsAt: Date? = (next_character_count_reset_unix.map {
            $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil
        } ?? nil)

        return [
            UsageWindow(label: "Monthly characters",
                        usedPercent: usedPercent,
                        resetsAt: resetsAt,
                        kind: .weekly,
                        windowSeconds: nil)
        ]
    }
}
