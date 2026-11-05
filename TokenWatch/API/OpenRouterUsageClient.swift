//
//  OpenRouterUsageClient.swift
//  TokenWatch
//
//  OpenRouter `GET /api/v1/credits` 호출 → 계정 전체의 남은 크레딧 잔액을 잔액 창으로 반환.
//  인증: **관리 키(Management Key)** Bearer. 공식 문서상 이 엔드포인트는 관리 키 전용이고,
//  일반 API 키는 403("Only management keys can perform this operation")으로 거절된다.
//  워크스페이스 범위 관리 키도 조직 단위 엔드포인트에서는 403일 수 있다.
//  키별 사용액(`/key`)은 계정 잔액과 의미가 달라 대신 쓰지 않는다.
//  참고: https://openrouter.ai/docs/api/api-reference/credits/get-remaining-credits
//

import Foundation

enum OpenRouterUsageClient {
    static let creditsURL = "https://openrouter.ai/api/v1/credits"

    static func fetch(tokens: OAuthTokens) async throws -> [UsageWindow] {
        var req = URLRequest(url: URL(string: creditsURL)!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("TokenWatch/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await APISession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if let error = statusError(status, retryAfter: http?.value(forHTTPHeaderField: "Retry-After"),
                                   body: data) {
            throw error
        }
        return try windows(from: data)
    }

    /// 비정상 상태 코드 → 오류(순수 함수 — 테스트 대상). 2xx면 nil.
    /// 401·403은 무엇을 해야 하는지 알려 주는 안내로 바꾼다 — 성공·잔액 0·"인증 만료"로 뭉개지 않는다.
    static func statusError(_ status: Int, retryAfter: String?, body: Data) -> UsageError? {
        let loc = L10n(lang: currentLang())
        switch status {
        case 200..<300: return nil
        case 401: return .keyRejected(status: 401, message: loc.errOpenRouterKeyRejected)
        case 403: return .keyRejected(status: 403, message: loc.errOpenRouterNeedsManagementKey)
        case 429: return .rateLimited(parseRetryAfter(retryAfter))
        default: return .http(status, String(data: body, encoding: .utf8) ?? "")
        }
    }

    /// 2xx 본문 → 잔액 창(순수 함수 — 테스트 대상). 필수 필드가 없으면 0으로 메우지 않고 해석 실패로 둔다.
    static func windows(from data: Data) throws -> [UsageWindow] {
        do {
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard let total = decoded.data?.total_credits, let usage = decoded.data?.total_usage else {
                throw UsageError.decode("missing credits fields")
            }
            let remaining = total - usage
            let value = String(format: "%.2f credits left", max(remaining, 0))
            return [UsageWindow(label: "Credits", usedPercent: 0, resetsAt: nil,
                                kind: .weekly, style: .balance, valueText: value,
                                balanceRemaining: max(remaining, 0), balanceTotal: total)]
        } catch let error as UsageError {
            throw error
        } catch {
            throw UsageError.decode(error.localizedDescription)
        }
    }

    private struct Response: Decodable {
        let data: Credits?
        struct Credits: Decodable {
            let total_credits: Double?
            let total_usage: Double?
        }
    }
}
