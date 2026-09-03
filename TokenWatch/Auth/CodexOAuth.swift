//
//  CodexOAuth.swift
//  TokenWatch
//
//  Codex(OpenAI/ChatGPT) OAuth (PKCE) 로그인 / 토큰 교환 / 갱신.
//
//  ⚠️ authorize·token 파라미터는 Codex CLI의 OAuth 흐름을 기반으로 재현했다
//     (client_id·refresh는 TokenBar agent_usage.rs에서 확인). redirect는
//     Codex CLI와 동일한 로컬 콜백을 쓰되, iOS에선 WKWebView가 그 URL로
//     네비게이트하기 직전에 가로채 code를 얻는다(실제 로컬 서버 없음).
//     정확한 파라미터는 실제 로그인으로 검증하며 아래 상수만 조정하면 된다.
//

import Foundation

enum CodexOAuth {
    // MARK: 설정 상수 (검증 대상)
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let authorizeURL = "https://auth.openai.com/oauth/authorize"
    static let tokenURL = "https://auth.openai.com/oauth/token"
    static let redirectURI = "http://localhost:1455/auth/callback"
    static let scopes = ["openid", "profile", "email", "offline_access"]
    static let callbackPrefix = "http://localhost:1455/auth/callback"

    // MARK: authorize URL

    static func authorizeURL(pkce: PKCE) -> URL {
        var comp = URLComponents(string: authorizeURL)!
        comp.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "state", value: pkce.state),
        ]
        return comp.url!
    }

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
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": pkce.verifier,
        ])
        let resp = try await postToken(body, contentType: .form)
        return tokens(from: resp, previous: nil)
    }

    static func refresh(tokens previous: OAuthTokens) async throws -> OAuthTokens {
        guard let refresh = previous.refreshToken else { throw OAuthError.notAuthenticated }
        // Codex refresh는 JSON 본문(TokenBar refresh_codex_credentials).
        let json: [String: String] = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "scope": "openid profile email",
        ]
        let body = try JSONSerialization.data(withJSONObject: json)
        let resp = try await postToken(body, contentType: .json)
        return tokens(from: resp, previous: previous)
    }

    // MARK: 내부

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
        let expires_in: Int?
    }

    private static func tokens(from r: TokenResponse, previous: OAuthTokens?) -> OAuthTokens {
        let idToken = r.id_token ?? previous?.idToken
        let email = idToken.flatMap(JWT.email) ?? previous?.accountEmail
        let plan = idToken.flatMap(JWT.plan) ?? previous?.plan
        let accountId = idToken.flatMap(JWT.accountID) ?? previous?.accountId
        return OAuthTokens(
            accessToken: r.access_token,
            refreshToken: r.refresh_token ?? previous?.refreshToken,
            expiresAt: r.expires_in.map { Date().addingTimeInterval(TimeInterval($0)) },
            scopes: scopes,
            accountEmail: email,
            plan: plan,
            idToken: idToken,
            accountId: accountId
        )
    }

    private enum ContentType { case form, json }

    private static func postToken(_ body: Data, contentType: ContentType) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: tokenURL)!)
        req.httpMethod = "POST"
        switch contentType {
        case .form: req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        case .json: req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = body

        let (data, response) = try await APISession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            // 로테이션으로 무효화된 refresh token — 재시도 불가, 재로그인 안내로 바꾼다.
            if status == 400 || status == 401, msg.contains("invalid_grant") {
                throw OAuthError.refreshRevoked
            }
            throw OAuthError.exchangeFailed("HTTP \(status): \(msg)")
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw OAuthError.exchangeFailed(L10n(lang: currentLang()).errParse(error.localizedDescription))
        }
    }

    private static func form(_ params: [String: String]) -> Data {
        var comp = URLComponents()
        comp.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((comp.percentEncodedQuery ?? "").utf8)
    }
}
