//
//  ClaudeUsageClient.swift
//  TokenWatch
//
//  Claude `/api/oauth/usage` 호출 → 사용량 창 매핑.
//  (참고: TokenBar agent_usage.rs fetch_claude_oauth_usage)
//

import Foundation

enum ClaudeUsageClient {
    static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    static let betaHeader = "oauth-2025-04-20"

    /// 에이전트의 저장된 토큰으로 사용량 스냅샷을 가져온다.
    /// - 429 backoff 게이트: 차단 중이면 마지막 성공값을 반환(네트워크 호출 생략).
    /// - 401(만료): 한 번 refresh 후 재시도.
    static func fetchSnapshot(for agentID: UUID) async -> AgentSnapshot {
        // 게이트가 닫혀있으면 마지막 성공 스냅샷을 그대로 사용.
        if let until = await RateLimitGate.shared.blocked(for: agentID) {
            if let cached = await RateLimitGate.shared.lastGood(for: agentID) {
                return cached
            }
            let secs = max(0, Int(until.timeIntervalSinceNow))
            return AgentSnapshot(windows: [], planLabel: nil, fetchedAt: Date(),
                                 error: "요청이 많아 잠시 대기 중입니다. 약 \(secs / 60 + 1)분 후 재시도합니다.")
        }

        do {
            let token = try await TokenStore.shared.validAccessToken(for: agentID)
            let snapshot: AgentSnapshot
            do {
                snapshot = try await fetch(accessToken: token)
            } catch UsageError.unauthorized {
                // 저장 토큰이 서버에서 거부됨 → 강제 refresh 재시도.
                let refreshed = try await forceRefresh(for: agentID)
                snapshot = try await fetch(accessToken: refreshed)
            }
            await RateLimitGate.shared.recordSuccess(for: agentID, snapshot)
            return snapshot
        } catch UsageError.rateLimited(let retryAfter) {
            await RateLimitGate.shared.recordRateLimit(for: agentID, retryAfter: retryAfter)
            if let cached = await RateLimitGate.shared.lastGood(for: agentID) { return cached }
            return AgentSnapshot(windows: [], planLabel: nil, fetchedAt: Date(),
                                 error: "요청이 많아 잠시 대기 중입니다.")
        } catch {
            return AgentSnapshot(windows: [], planLabel: nil, fetchedAt: Date(),
                                 error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private static func forceRefresh(for agentID: UUID) async throws -> String {
        guard let tokens = await TokenStore.shared.tokens(for: agentID),
              let refresh = tokens.refreshToken else {
            throw OAuthError.notAuthenticated
        }
        let new = try await ClaudeOAuth.refresh(refresh, scopes: tokens.scopes, previous: tokens)
        await TokenStore.shared.save(new, for: agentID)
        return new.accessToken
    }

    enum UsageError: Error {
        case unauthorized
        case rateLimited(Date?)
        case http(Int, String)
        case decode(String)
    }

    static func fetch(accessToken: String) async throws -> AgentSnapshot {
        var req = URLRequest(url: URL(string: usageURL)!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue("TokenWatch/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 { throw UsageError.unauthorized }
        if status == 429 {
            throw UsageError.rateLimited(parseRetryAfter(http?.value(forHTTPHeaderField: "Retry-After")))
        }
        guard (200..<300).contains(status) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw UsageError.http(status, msg)
        }
        do {
            let decoded = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
            let windows = ClaudeUsageMapper.windows(from: decoded)
            return AgentSnapshot(windows: windows, planLabel: nil, fetchedAt: Date(), error: nil)
        } catch {
            throw UsageError.decode(error.localizedDescription)
        }
    }

    /// Retry-After: 초 단위 정수 또는 HTTP-date. 파싱 실패 시 nil(→기본 backoff).
    private static func parseRetryAfter(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let secs = TimeInterval(value) { return Date().addingTimeInterval(secs) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: value)
    }
}

extension ClaudeUsageClient.UsageError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unauthorized: return "인증이 만료되었습니다. 다시 로그인해 주세요."
        case .rateLimited: return "요청이 많아 잠시 대기 중입니다."
        case .http(let code, _): return "사용량 조회 실패 (HTTP \(code))."
        case .decode(let m): return "응답 해석 실패: \(m)"
        }
    }
}
