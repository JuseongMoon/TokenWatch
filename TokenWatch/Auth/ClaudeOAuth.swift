//
//  ClaudeOAuth.swift
//  TokenWatch
//
//  Claude OAuth (PKCE) 로그인 / 토큰 교환 / 갱신.
//
//  ⚠️ authorize·token 엔드포인트와 파라미터는 Claude Code CLI의 OAuth 흐름을 기반으로
//     재현한 값이다(참고: TokenBar `agent_usage.rs`의 CLAUDE_CLIENT_ID / refresh URL).
//     실제 로그인으로 검증하며 필요 시 아래 상수만 조정하면 된다.
//

import Foundation

/// 저장되는 토큰 세트.
struct OAuthTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var scopes: [String]
    /// 로그인 계정 이메일 (토큰 교환 응답의 account.email_address). 없을 수 있다.
    var accountEmail: String?
    /// 구독 플랜/조직 라벨 (이메일이 없을 때 폴백).
    var plan: String?
    /// OIDC id_token (Codex는 여기서 이메일/플랜/account_id를 파싱). Claude는 미사용.
    var idToken: String? = nil
    /// Codex 계정 ID (usage 요청의 ChatGPT-Account-Id 헤더). Claude는 미사용.
    var accountId: String? = nil

    var isExpired: Bool {
        guard let expiresAt else { return false }
        // 120초 여유를 두고 만료로 간주. 백그라운드에서 깨어난 직후처럼 왕복이 느린
        // 상황에서 "아슬아슬하게 유효한" 토큰으로 요청해 401→강제 갱신을 타지 않게 한다.
        return Date() >= expiresAt.addingTimeInterval(-120)
    }
}

enum OAuthError: LocalizedError {
    case exchangeFailed(String)
    case refreshFailed(String)
    /// 서버가 refresh token 자체를 거부(invalid_grant) — 재시도로 복구되지 않는다.
    /// 로테이션으로 무효화됐거나 만료된 경우로, 재로그인 외에는 방법이 없다.
    case refreshRevoked
    case notAuthenticated

    var errorDescription: String? {
        let loc = L10n(lang: currentLang())
        switch self {
        case .exchangeFailed(let m): return loc.errTokenExchange(m)
        case .refreshFailed(let m): return loc.errTokenRefresh(m)
        case .refreshRevoked: return loc.errAuthExpired
        case .notAuthenticated: return loc.errNotAuthenticated
        }
    }
}

enum ClaudeOAuth {
    // MARK: 설정 상수 (검증 대상)
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = "https://claude.ai/oauth/authorize"
    static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let scopes = ["org:create_api_key", "user:profile", "user:inference"]

    /// 이 콜백 경로로 리다이렉트되면 code/state를 뽑아낸다.
    static let callbackPrefix = "https://console.anthropic.com/oauth/code/callback"

    /// 1단계(로그인만)용 주소. 인가 파라미터가 없어 앱은 아무것도 기다리지 않는다.
    /// `/login`은 claude.ai의 유니버설 링크 대상 경로가 아니라 Safari로 열린다(AASA 확인).
    static let loginURL = URL(string: "https://claude.ai/login")!

    /// 외부 브라우저 로그인에서 쓰는 루프백 콜백. 앱이 띄운 `LoopbackCallbackServer`가 받는다.
    static func loopbackRedirectURI(port: UInt16) -> String {
        "http://localhost:\(port)/callback"
    }

    // MARK: authorize URL

    /// - Parameter redirect: 기본값은 콘솔 코드 페이지(수동 복사 흐름). 외부 브라우저
    ///   자동 수신 흐름에서는 `loopbackRedirectURI(port:)`를 넘긴다.
    static func authorizeURL(pkce: PKCE, redirect: String? = nil) -> URL {
        var comp = URLComponents(string: authorizeURL)!
        comp.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirect ?? redirectURI),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: pkce.state),
        ]
        return comp.url!
    }

    /// 콜백 URL에서 code/state 추출. 콜백 매칭이 아니면 nil.
    static func parseCallback(_ url: URL) -> (code: String, state: String)? {
        guard url.absoluteString.hasPrefix(callbackPrefix),
              let comp = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let items = comp.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value else { return nil }
        let state = items.first(where: { $0.name == "state" })?.value ?? ""
        return (code, state)
    }

    /// 사용자가 콘솔 페이지에서 복사해 붙여넣은 문자열에서 code/state를 뽑는다.
    /// 콘솔은 `code#state` 형태로 보여주지만, code만 복사해 오는 경우도 흔해
    /// state가 없으면 우리가 시작할 때 만든 값(`fallbackState`)으로 채운다.
    /// 콜백 URL을 통째로 붙여넣은 경우도 받아준다.
    static func parseManualCode(_ text: String, fallbackState: String) -> (code: String, state: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("http"), let url = URL(string: trimmed), let parsed = parseCallback(url) {
            return (parsed.code, parsed.state.isEmpty ? fallbackState : parsed.state)
        }

        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let code = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return nil }
        let state = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (code, state.isEmpty ? fallbackState : state)
    }

    // MARK: 토큰 교환 / 갱신

    /// - Parameter redirect: authorize에 쓴 값과 반드시 같아야 한다(OAuth 규약).
    ///   nil이면 기본 콘솔 콜백(`redirectURI`).
    static func exchange(code: String, state: String, pkce: PKCE,
                         redirect: String? = nil) async throws -> OAuthTokens {
        let body = form([
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": clientID,
            "redirect_uri": redirect ?? redirectURI,
            "code_verifier": pkce.verifier,
        ])
        do {
            let resp = try await postTokenRetryingTransientFailure(body)
            return tokens(from: resp, fallbackScopes: scopes, previousRefresh: nil)
        } catch let e as OAuthError {
            if case .refreshFailed(let m) = e { throw OAuthError.exchangeFailed(m) }
            // 교환 단계의 invalid_grant는 "코드 만료/재사용"이다. postToken은 이를
            // refresh 관점의 .refreshRevoked("재로그인 필요")로 바꾸는데, 붙여넣기
            // 흐름에서는 오해를 부르므로 코드 문구로 되돌린다.
            if case .refreshRevoked = e {
                throw OAuthError.exchangeFailed(L10n(lang: currentLang()).errCodeExpired)
            }
            throw e
        }
    }

    /// 저장된 토큰으로 갱신하는 편의 래퍼(디스패치 레이어에서 사용).
    static func refresh(tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refresh = tokens.refreshToken else { throw OAuthError.notAuthenticated }
        return try await self.refresh(refresh, scopes: tokens.scopes, previous: tokens)
    }

    static func refresh(_ refreshToken: String, scopes: [String], previous: OAuthTokens? = nil) async throws -> OAuthTokens {
        let body = form([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
        let resp = try await postToken(body)
        return tokens(from: resp, fallbackScopes: scopes, previousRefresh: refreshToken, previous: previous)
    }

    // MARK: 내부

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
        let account: Account?
        let organization: Organization?

        struct Account: Decodable {
            let email_address: String?
            let email: String?
        }
        struct Organization: Decodable {
            let name: String?
        }
    }

    private static func tokens(from r: TokenResponse, fallbackScopes: [String],
                               previousRefresh: String?, previous: OAuthTokens? = nil) -> OAuthTokens {
        let email = r.account?.email_address ?? r.account?.email ?? previous?.accountEmail
        let plan = r.organization?.name ?? previous?.plan
        return OAuthTokens(
            accessToken: r.access_token,
            refreshToken: r.refresh_token ?? previousRefresh,
            expiresAt: r.expires_in.map { Date().addingTimeInterval(TimeInterval($0)) },
            scopes: fallbackScopes,
            accountEmail: email,
            plan: plan
        )
    }

    /// 교환 전용: 앱이 백그라운드 정지에서 막 깨어난 직후의 첫 요청은 시스템이 닫아 둔
    /// 소켓 때문에 "network connection was lost"(-1005)로 끊기기 쉽다. 이런 일시적
    /// 오류는 요청이 서버에 닿기 전에 실패한 것이라 인가 코드가 아직 유효하므로 한 번 더
    /// 보낸다. (refresh에는 쓰지 않는다 — refresh token은 서버 도달 시 로테이션되어
    /// 재전송이 자격증명을 죽일 수 있다.)
    private static func postTokenRetryingTransientFailure(_ body: Data) async throws -> TokenResponse {
        do {
            return try await postToken(body)
        } catch let e as URLError where isTransient(e) {
            try await Task.sleep(for: .seconds(1))
            return try await postToken(body)
        }
    }

    static func isTransient(_ e: URLError) -> Bool {
        switch e.code {
        case .networkConnectionLost, .timedOut, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private static func postToken(_ body: Data) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = body

        let (data, response) = try await APISession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            // invalid_grant는 영구 실패다. 원문 JSON을 카드에 흘리지 않고 재로그인 안내로 바꾼다.
            if status == 400 || status == 401, msg.contains("invalid_grant") {
                throw OAuthError.refreshRevoked
            }
            throw OAuthError.refreshFailed("HTTP \(status): \(msg)")
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw OAuthError.refreshFailed(L10n(lang: currentLang()).errParse(error.localizedDescription))
        }
    }

    private static func form(_ params: [String: String]) -> Data {
        var comp = URLComponents()
        comp.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((comp.percentEncodedQuery ?? "").utf8)
    }
}
