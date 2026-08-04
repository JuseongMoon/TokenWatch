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
        // 60초 여유를 두고 만료로 간주.
        return Date() >= expiresAt.addingTimeInterval(-60)
    }
}

enum OAuthError: LocalizedError {
    case exchangeFailed(String)
    case refreshFailed(String)
    case notAuthenticated

    var errorDescription: String? {
        let loc = L10n(lang: currentLang())
        switch self {
        case .exchangeFailed(let m): return loc.errTokenExchange(m)
        case .refreshFailed(let m): return loc.errTokenRefresh(m)
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

    // MARK: authorize URL

    static func authorizeURL(pkce: PKCE) -> URL {
        var comp = URLComponents(string: authorizeURL)!
        comp.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
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

    // MARK: 토큰 교환 / 갱신

    static func exchange(code: String, state: String, pkce: PKCE) async throws -> OAuthTokens {
        let body = form([
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": pkce.verifier,
        ])
        do {
            let resp = try await postToken(body)
            return tokens(from: resp, fallbackScopes: scopes, previousRefresh: nil)
        } catch let e as OAuthError {
            if case .refreshFailed(let m) = e { throw OAuthError.exchangeFailed(m) }
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
