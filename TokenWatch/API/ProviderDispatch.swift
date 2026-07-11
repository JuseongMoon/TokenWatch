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
        let loc = L10n(lang: currentLang())
        switch self {
        case .unauthorized: return loc.errAuthExpired
        case .rateLimited: return loc.errRateLimited
        case .http(let code, _): return loc.errHTTP(code)
        case .decode(let m): return loc.errDecode(m)
        case .noWindows: return loc.errNoWindows
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
    // 아래 authorizeURL/parseCallback/exchange/refresh는 oauthCode 방식 provider 전용이다.
    // apiKey/deviceFlow provider는 AddAgentSheet가 이 경로로 오지 않도록 라우팅한다.

    static func authorizeURL(_ provider: AgentProvider, pkce: PKCE) -> URL {
        switch provider {
        case .claude: return ClaudeOAuth.authorizeURL(pkce: pkce)
        case .codex: return CodexOAuth.authorizeURL(pkce: pkce)
        default: preconditionFailure("authorizeURL는 oauthCode provider 전용입니다: \(provider)")
        }
    }

    static func parseCallback(_ provider: AgentProvider, _ url: URL) -> (code: String, state: String)? {
        switch provider {
        case .claude: return ClaudeOAuth.parseCallback(url)
        case .codex: return CodexOAuth.parseCallback(url)
        default: return nil
        }
    }

    static func exchange(_ provider: AgentProvider, code: String, state: String, pkce: PKCE) async throws -> OAuthTokens {
        switch provider {
        case .claude: return try await ClaudeOAuth.exchange(code: code, state: state, pkce: pkce)
        case .codex: return try await CodexOAuth.exchange(code: code, state: state, pkce: pkce)
        default: throw OAuthError.notAuthenticated
        }
    }

    static func refresh(_ provider: AgentProvider, _ tokens: OAuthTokens) async throws -> OAuthTokens {
        switch provider {
        case .claude: return try await ClaudeOAuth.refresh(tokens: tokens)
        case .codex: return try await CodexOAuth.refresh(tokens: tokens)
        // apiKey/세션 자격증명은 refresh 개념이 없다(만료 없음). 401 시 재로그인 유도.
        default: throw OAuthError.notAuthenticated
        }
    }

    /// apiKey 방식 provider: 사용자가 입력한 키를 저장용 자격증명으로 만든다.
    /// (키 유효성은 이후 첫 usage 조회에서 판별된다.) provider별 특수 처리가
    /// 필요하면 여기서 분기한다.
    static func credential(_ provider: AgentProvider, apiKey: String) -> OAuthTokens {
        OAuthTokens.apiKey(apiKey)
    }

    // MARK: sessionCapture 디스패치

    /// sessionCapture provider가 무엇을 관찰해 토큰을 잡는지.
    enum SessionCaptureMode { case cookie, localStorage }

    static func sessionCaptureMode(_ provider: AgentProvider) -> SessionCaptureMode {
        switch provider {
        case .windsurf: return .localStorage
        default: return .cookie
        }
    }

    /// sessionCapture provider의 로그인 웹뷰 시작 URL. 미지원이면 nil.
    static func sessionLoginURL(_ provider: AgentProvider) -> URL? {
        switch provider {
        case .cursor: return CursorAuth.loginURL
        case .grok: return GrokAuth.loginURL
        case .windsurf: return WindsurfAuth.loginURL
        default: return nil
        }
    }

    /// 로그인 후 쿠키에서 세션 자격증명을 추출한다(cookie 모드).
    static func sessionProbe(_ provider: AgentProvider, cookies: [HTTPCookie]) -> OAuthTokens? {
        switch provider {
        case .cursor: return CursorAuth.sessionProbe(cookies)
        case .grok: return GrokAuth.sessionProbe(cookies)
        default: return nil
        }
    }

    /// 로그인 후 localStorage에서 세션 자격증명을 추출한다(localStorage 모드).
    static func localStorageProbe(_ provider: AgentProvider, store: [String: String]) -> OAuthTokens? {
        switch provider {
        case .windsurf: return WindsurfAuth.localStorageProbe(store)
        default: return nil
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
        case .elevenlabs: return try await ElevenLabsUsageClient.fetch(tokens: tokens)
        case .copilot: return try await CopilotUsageClient.fetch(tokens: tokens)
        case .cursor: return try await CursorUsageClient.fetch(tokens: tokens)
        case .openrouter: return try await OpenRouterUsageClient.fetch(tokens: tokens)
        case .deepseek: return try await DeepSeekUsageClient.fetch(tokens: tokens)
        case .poe: return try await PoeUsageClient.fetch(tokens: tokens)
        case .fal: return try await FalUsageClient.fetch(tokens: tokens)
        case .stability: return try await StabilityUsageClient.fetch(tokens: tokens)
        case .recraft: return try await RecraftUsageClient.fetch(tokens: tokens)
        case .luma: return try await LumaUsageClient.fetch(tokens: tokens)
        case .runway: return try await RunwayUsageClient.fetch(tokens: tokens)
        case .did: return try await DIDUsageClient.fetch(tokens: tokens)
        case .heygen: return try await HeyGenUsageClient.fetch(tokens: tokens)
        case .leonardo: return try await LeonardoUsageClient.fetch(tokens: tokens)
        case .grok: return try await GrokUsageClient.fetch(tokens: tokens)
        case .windsurf: return try await WindsurfUsageClient.fetch(tokens: tokens)
        }
    }

    /// 게이트/갱신/에러 처리를 포함한 스냅샷 조회(모든 provider 공통).
    static func fetchSnapshot(_ provider: AgentProvider, for agentID: UUID) async -> AgentSnapshot {
        // 429 backoff 게이트가 닫혀있으면 캐시 그래프를 유지하며 재시도 안내를 표시.
        if let until = await RateLimitGate.shared.blocked(for: agentID) {
            return await rateLimitedSnapshot(agentID: agentID, until: until)
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
            let until = await RateLimitGate.shared.blocked(for: agentID)
                ?? Date().addingTimeInterval(300)
            return await rateLimitedSnapshot(agentID: agentID, until: until)
        } catch {
            return AgentSnapshot(windows: [], planLabel: nil, fetchedAt: Date(),
                                 error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// 429 백오프 중 표시할 스냅샷. 캐시된 마지막 성공 그래프가 있으면 그 그래프를 그대로
    /// 유지하되 "갱신 정지" 안내를 얹고(그래프는 지워지지 않는다), 캐시가 없으면 빈 그래프에
    /// 재시도 메시지만 표시한다.
    private static func rateLimitedSnapshot(agentID: UUID, until: Date) async -> AgentSnapshot {
        let mins = max(1, Int(until.timeIntervalSinceNow) / 60 + 1)
        let lang = currentLang()
        if let cached = await RateLimitGate.shared.lastGood(for: agentID) {
            return AgentSnapshot(windows: cached.windows, planLabel: cached.planLabel,
                                 fetchedAt: cached.fetchedAt,
                                 error: L10n(lang: lang).errRateLimitedRetryStale(mins))
        }
        return AgentSnapshot(windows: [], planLabel: nil, fetchedAt: Date(),
                             error: L10n(lang: lang).errRateLimitedRetry(mins))
    }
}
