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

extension FetchErrorReason {
    /// usage 조회 에러를 분석용 기계 사유로 정규화한다. 원문 메시지는 현지화 문자열이라
    /// 전송하지 않고(계정 정보·URL 혼입 가능), 이 열거값만 usage_fetch_error에 실린다.
    init(classifying error: Error) {
        switch error {
        case UsageError.unauthorized: self = .auth
        case UsageError.rateLimited: self = .rateLimit
        case UsageError.http(let code, _): self = code >= 500 ? .http5xx : .http4xx
        case UsageError.decode: self = .parse
        case UsageError.noWindows: self = .empty
        case is OAuthError: self = .auth   // 토큰 refresh 실패 → 재로그인 필요
        case is URLError: self = .network
        default: self = .other
        }
    }
}

/// Retry-After 헤더 파싱: 초 단위 정수 또는 HTTP-date.
/// `Double(String)`은 "inf"·"1e400" 같은 값도 성공 파싱하므로, 비유한·음수는 버리고
/// 과대 값은 상한으로 눌러야 한다 — 무한대 Date가 백오프 표시 계산의 `Int(...)` 변환까지
/// 흘러가면 그대로 트랩(크래시)한다.
func parseRetryAfter(_ value: String?, now: Date = Date()) -> Date? {
    /// 서버가 어떤 값을 보내든 이 이상은 기다리지 않는다.
    let maxRetryAfter: TimeInterval = 24 * 60 * 60
    guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
    if let secs = TimeInterval(value) {
        guard secs.isFinite, secs >= 0 else { return nil }
        return now.addingTimeInterval(min(secs, maxRetryAfter))
    }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    guard let date = f.date(from: value) else { return nil }
    return min(date, now.addingTimeInterval(maxRetryAfter))
}

// MARK: - OAuth 디스패치

enum ProviderAuth {
    // 아래 authorizeURL/parseCallback/exchange/refresh는 OAuth 인가코드 방식
    // provider(oauthBrowser=Claude·Grok, oauthCode=Codex) 전용이다.
    // apiKey/deviceFlow provider는 AddAgentSheet가 이 경로로 오지 않도록 라우팅한다.
    // switch에 `default:`를 두지 않는다 — 새 provider를 추가하며 여기를 빠뜨리면 컴파일 에러로
    // 드러나야 한다(빠뜨린 채 빌드되면 로그인 크래시나 "로그인 필요"가 조용히 난다).

    /// - Parameter redirect: 인증 시트 로그인에서 루프백 콜백을 쓸 때만 넘긴다.
    ///   (Claude·Grok. Codex는 콜백이 고정이라 무시한다. Grok은 루프백 redirect가 반드시 있어야 한다.)
    static func authorizeURL(_ provider: AgentProvider, pkce: PKCE, redirect: String? = nil) -> URL {
        switch provider {
        case .claude: return ClaudeOAuth.authorizeURL(pkce: pkce, redirect: redirect)
        case .codex: return CodexOAuth.authorizeURL(pkce: pkce)
        case .grok:
            guard let redirect else { preconditionFailure("Grok authorizeURL에는 루프백 redirect가 필요합니다") }
            return GrokOAuth.authorizeURL(pkce: pkce, redirect: redirect)
        case .copilot, .cursor, .openrouter, .deepseek, .poe, .elevenlabs:
            preconditionFailure("authorizeURL는 OAuth provider 전용입니다: \(provider)")
        }
    }

    static func parseCallback(_ provider: AgentProvider, _ url: URL) -> (code: String, state: String)? {
        switch provider {
        case .claude: return ClaudeOAuth.parseCallback(url)
        case .codex: return CodexOAuth.parseCallback(url)
        // Grok 콜백은 루프백 리스너가 직접 파싱한다(웹뷰 가로채기 경로가 아니다).
        case .grok, .copilot, .cursor, .openrouter, .deepseek, .poe, .elevenlabs: return nil
        }
    }

    /// 인증 시트 로그인(oauthBrowser)의 루프백 redirect_uri. 루프백 콜백을 쓰지 않는 provider는 nil.
    static func loopbackRedirectURI(_ provider: AgentProvider, port: UInt16) -> String? {
        switch provider {
        case .claude: return ClaudeOAuth.loopbackRedirectURI(port: port)
        case .grok: return GrokOAuth.loopbackRedirectURI(port: port)
        case .codex, .copilot, .cursor, .openrouter, .deepseek, .poe, .elevenlabs: return nil
        }
    }

    /// 코드 붙여넣기 폴백이 쓰는 redirect_uri(콘솔 코드 페이지). 이 폴백이 없는 provider는 nil이고,
    /// 인증 시트 로그인 화면은 그때 수동 입력 버튼을 숨긴다.
    static func manualCodeRedirect(_ provider: AgentProvider) -> String? {
        switch provider {
        case .claude: return ClaudeOAuth.redirectURI
        case .codex, .grok, .copilot, .cursor, .openrouter, .deepseek, .poe, .elevenlabs: return nil
        }
    }

    /// - Parameter redirect: authorize에 쓴 redirect_uri와 같은 값을 넘겨야 한다.
    static func exchange(_ provider: AgentProvider, code: String, state: String, pkce: PKCE,
                         redirect: String? = nil) async throws -> OAuthTokens {
        switch provider {
        case .claude:
            return try await ClaudeOAuth.exchange(code: code, state: state, pkce: pkce, redirect: redirect)
        case .codex: return try await CodexOAuth.exchange(code: code, state: state, pkce: pkce)
        case .grok:
            // 루프백으로 받은 code만 있다(코드 붙여넣기 폴백 없음).
            guard let redirect else { throw OAuthError.notAuthenticated }
            return try await GrokOAuth.exchange(code: code, pkce: pkce, redirect: redirect)
        case .copilot, .cursor, .openrouter, .deepseek, .poe, .elevenlabs: throw OAuthError.notAuthenticated
        }
    }

    static func refresh(_ provider: AgentProvider, _ tokens: OAuthTokens) async throws -> OAuthTokens {
        switch provider {
        case .claude: return try await ClaudeOAuth.refresh(tokens: tokens)
        case .codex: return try await CodexOAuth.refresh(tokens: tokens)
        case .grok: return try await GrokOAuth.refresh(tokens: tokens)
        // device flow·API 키 자격증명은 refresh 개념이 없다(만료 없음). 401 시 재로그인 유도.
        // Cursor v1도 refresh 없이 토큰(약 60일)이 만료되면 다시 로그인한다.
        case .copilot, .cursor, .openrouter, .deepseek, .poe, .elevenlabs: throw OAuthError.notAuthenticated
        }
    }

    /// apiKey 방식 provider: 사용자가 입력한 키를 저장용 자격증명으로 만든다.
    /// (키 유효성은 이후 첫 usage 조회에서 판별된다.) provider별 특수 처리가
    /// 필요하면 여기서 분기한다.
    static func credential(_ provider: AgentProvider, apiKey: String) -> OAuthTokens {
        OAuthTokens.apiKey(apiKey)
    }

    /// 폴링 로그인(`.oauthDeviceFlow`)을 시작한다 — 승인 페이지 정보와, 승인될 때까지 토큰을 기다리는 폴러.
    /// 다른 인증 방식 provider는 AddAgentSheet가 이 경로로 보내지 않는다.
    static func startPollingLogin(_ provider: AgentProvider) async throws -> PollingLogin {
        switch provider {
        case .copilot:
            let device = try await CopilotDeviceFlow.requestDeviceCode()
            return PollingLogin(userCode: device.userCode, verificationURL: device.verificationURI,
                                poll: { try await CopilotDeviceFlow.pollForToken(device) })
        case .cursor:
            let handshake = CursorAuth.makeHandshake()
            return PollingLogin(userCode: nil, verificationURL: handshake.loginURL,
                                poll: { try await CursorAuth.completeLogin(handshake) })
        case .claude, .codex, .grok, .openrouter, .deepseek, .poe, .elevenlabs:
            throw OAuthError.notAuthenticated
        }
    }
}

/// 폴링 로그인 한 번: 승인 페이지를 앱 안 Safari View로 열어 두고, 승인될 때까지 토큰을 폴링한다.
/// Copilot은 발급받은 코드를 페이지에 입력하고, 페이지 승인만으로 끝나는 흐름은 코드가 없다.
struct PollingLogin {
    /// 승인 페이지에 입력할 코드. 코드 없이 승인만 하는 흐름은 nil.
    let userCode: String?
    /// 승인(로그인) 페이지.
    let verificationURL: URL?
    /// 승인될 때까지 기다려 토큰을 돌려준다. 만료·거부 시 throw, 화면 이탈(Task 취소) 시 CancellationError.
    let poll: () async throws -> OAuthTokens
}

// MARK: - Usage 디스패치 + 공통 오케스트레이션

enum ProviderUsage {
    /// provider별 사용량 창을 가져온다(토큰만 받는 순수 네트워크 호출).
    static func fetchWindows(_ provider: AgentProvider, tokens: OAuthTokens) async throws -> [UsageWindow] {
        switch provider {
        case .claude: return try await ClaudeUsageClient.fetch(tokens: tokens)
        case .codex: return try await CodexUsageClient.fetch(tokens: tokens)
        case .copilot: return try await CopilotUsageClient.fetch(tokens: tokens)
        case .grok: return try await GrokUsageClient.fetch(tokens: tokens)
        case .cursor: return try await CursorUsageClient.fetch(tokens: tokens)
        case .openrouter: return try await OpenRouterUsageClient.fetch(tokens: tokens)
        case .deepseek: return try await DeepSeekUsageClient.fetch(tokens: tokens)
        case .poe: return try await PoeUsageClient.fetch(tokens: tokens)
        case .elevenlabs: return try await ElevenLabsUsageClient.fetch(tokens: tokens)
        }
    }

    /// 게이트/갱신/에러 처리를 포함한 스냅샷 조회(모든 provider 공통).
    ///
    /// - Parameter manual: 사용자가 직접 [refresh]를 눌렀을 때 true. 버스트 스로틀을 우회하고,
    ///   Codex는 이때 accounts/check에서 현재 plan을 라이브로 읽어 갱신한다(아래 설명 참고).
    ///   자동 새로고침은 false로 두어 여분의 호출을 매 틱 하지 않는다.
    /// - Returns: 취소(백그라운드 전환·주기 변경 등)로 중단되면 nil — 취소는 에러가
    ///   아니므로 호출자는 표시 중인 스냅샷을 건드리지 않아야 한다.
    static func fetchSnapshot(_ provider: AgentProvider, for agentID: UUID,
                             manual: Bool = false) async -> AgentSnapshot? {
        // 429 backoff 게이트가 닫혀있으면 캐시 그래프를 유지하며 재시도 안내를 표시.
        if let until = await RateLimitGate.shared.blocked(for: agentID) {
            return await rateLimitedSnapshot(agentID: agentID, until: until)
        }

        do {
            var tokens = try await TokenStore.shared.validTokens(for: agentID, provider: provider)
            let usage: (windows: [UsageWindow], plan: String?)
            do {
                usage = try await fetchUsage(provider, tokens: tokens)
            } catch UsageError.unauthorized {
                tokens = try await TokenStore.shared.forceRefresh(for: agentID, provider: provider)
                usage = try await fetchUsage(provider, tokens: tokens)
            }
            let windows = usage.windows

            // 200이지만 창이 하나도 없으면 성공으로 캐싱하지 않고 명시적 에러로 처리한다.
            // (조용히 빈 스냅샷을 저장하면 last-good 캐시까지 오염되고, 카드에는 이유 없는
            //  "no usage data"만 남는다.)
            guard !windows.isEmpty else { throw UsageError.noWindows }

            // 사용량 응답에 플랜 라벨이 실려 오는 provider(Grok·Cursor)는 토큰(Keychain)의 plan에
            // 반영한다. 추가 요청 없이 매 조회에 따라오므로 수동/자동을 가리지 않는다. 없으면 기존 값 유지.
            if let livePlan = usage.plan, livePlan != tokens.plan {
                tokens.plan = livePlan
                await TokenStore.shared.updatePlan(livePlan, for: agentID)
            }

            // Codex plan 라이브 갱신: id_token(JWT)의 chatgpt_plan_type은 최초 로그인 시점
            // 값에 고정되어 refresh로도 안 바뀐다(실증됨). 그래서 수동 새로고침 시에는
            // accounts/check 엔드포인트에서 현재 plan을 읽어 토큰(Keychain)까지 갱신한다.
            if provider == .codex, manual,
               let livePlan = try? await CodexAccountClient.fetchPlan(tokens: tokens),
               livePlan != tokens.plan {
                tokens.plan = livePlan
                await TokenStore.shared.updatePlan(livePlan, for: agentID)
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
        } catch is CancellationError {
            return nil
        } catch let e as URLError where e.code == .cancelled {
            return nil
        } catch {
            return AgentSnapshot(windows: [], planLabel: nil, fetchedAt: Date(),
                                 error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                                 errorReason: FetchErrorReason(classifying: error))
        }
    }

    /// 사용량 창 + 응답에 실려 오는 플랜 라벨. 플랜을 주지 않는 provider는 nil.
    private static func fetchUsage(_ provider: AgentProvider,
                                   tokens: OAuthTokens) async throws -> (windows: [UsageWindow], plan: String?) {
        switch provider {
        case .grok:
            return try await GrokUsageClient.fetchUsage(tokens: tokens)
        case .cursor:
            return try await CursorUsageClient.fetchUsage(tokens: tokens)
        case .claude, .codex, .copilot, .openrouter, .deepseek, .poe, .elevenlabs:
            return (try await fetchWindows(provider, tokens: tokens), nil)
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
                                 error: L10n(lang: lang).errRateLimitedRetryStale(mins),
                                 errorReason: .rateLimit)
        }
        return AgentSnapshot(windows: [], planLabel: nil, fetchedAt: Date(),
                             error: L10n(lang: lang).errRateLimitedRetry(mins),
                             errorReason: .rateLimit)
    }
}
