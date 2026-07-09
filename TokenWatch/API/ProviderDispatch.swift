//
//  ProviderDispatch.swift
//  TokenWatch
//
//  provider별 OAuth/usage 구현을 하나의 진입점으로 묶는 디스패치 레이어.
//  새 provider를 추가할 땐 여기 switch만 확장하면 된다.
//

import Foundation

// MARK: - 공용 에러

enum UsageError: Error, LocalizedError {
    case unauthorized
    case rateLimited(Date?)
    case http(Int, String)
    case decode(String)
    case noWindows

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "인증이 만료되었습니다. 다시 로그인해 주세요."
        case .rateLimited: return "요청이 많아 잠시 대기 중입니다."
        case .http(let code, _): return "사용량 조회 실패 (HTTP \(code))."
        case .decode(let m): return "응답 해석 실패: \(m)"
        case .noWindows: return "표시할 사용량 창이 없습니다."
        }
    }
}

/// Retry-After 헤더 파싱: 초 단위 정수 또는 HTTP-date.
func parseRetryAfter(_ value: String?) -> Date? {
    guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
    if let secs = TimeInterval(value) { return Date().addingTimeInterval(secs) }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return f.date(from: value)
}

// MARK: - OAuth 디스패치

enum ProviderAuth {
    static func authorizeURL(_ provider: AgentProvider, pkce: PKCE) -> URL {
        switch provider {
        case .claude: return ClaudeOAuth.authorizeURL(pkce: pkce)
        case .codex: return CodexOAuth.authorizeURL(pkce: pkce)
        }
    }

    static func parseCallback(_ provider: AgentProvider, _ url: URL) -> (code: String, state: String)? {
        switch provider {
        case .claude: return ClaudeOAuth.parseCallback(url)
        case .codex: return CodexOAuth.parseCallback(url)
        }
    }

    static func exchange(_ provider: AgentProvider, code: String, state: String, pkce: PKCE) async throws -> OAuthTokens {
        switch provider {
        case .claude: return try await ClaudeOAuth.exchange(code: code, state: state, pkce: pkce)
        case .codex: return try await CodexOAuth.exchange(code: code, state: state, pkce: pkce)
        }
    }

    static func refresh(_ provider: AgentProvider, _ tokens: OAuthTokens) async throws -> OAuthTokens {
        switch provider {
        case .claude: return try await ClaudeOAuth.refresh(tokens: tokens)
        case .codex: return try await CodexOAuth.refresh(tokens: tokens)
        }
    }
}

// MARK: - Usage 디스패치 + 공통 오케스트레이션

enum ProviderUsage {
    /// provider별 사용량 창을 가져온다(토큰만 받는 순수 네트워크 호출).
    static func fetchWindows(_ provider: AgentProvider, tokens: OAuthTokens) async throws -> [UsageWindow] {
        switch provider {
        case .claude: return try await ClaudeUsageClient.fetch(tokens: tokens)
        case .codex: return try await CodexUsageClient.fetch(tokens: tokens)
        }
    }

    /// 게이트/갱신/에러 처리를 포함한 스냅샷 조회(모든 provider 공통).
    static func fetchSnapshot(_ provider: AgentProvider, for agentID: UUID) async -> AgentSnapshot {
        // 429 backoff 게이트가 닫혀있으면 마지막 성공값을 사용.
        if let until = await RateLimitGate.shared.blocked(for: agentID) {
            if let cached = await RateLimitGate.shared.lastGood(for: agentID) { return cached }
            let mins = max(1, Int(until.timeIntervalSinceNow) / 60 + 1)
            return AgentSnapshot(windows: [], planLabel: nil, fetchedAt: Date(),
                                 error: "요청이 많아 잠시 대기 중입니다. 약 \(mins)분 후 재시도합니다.")
        }

        do {
            var tokens = try await TokenStore.shared.validTokens(for: agentID, provider: provider)
            let windows: [UsageWindow]
            do {
                windows = try await fetchWindows(provider, tokens: tokens)
            } catch UsageError.unauthorized {
                tokens = try await TokenStore.shared.forceRefresh(for: agentID, provider: provider)
                windows = try await fetchWindows(provider, tokens: tokens)
            }
            let snapshot = AgentSnapshot(windows: windows, planLabel: tokens.plan,
                                         fetchedAt: Date(), error: nil)
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
}
