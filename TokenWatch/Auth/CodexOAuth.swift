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
        let resp = try await postToken(body, contentType: .form, stage: .exchange)
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
        let resp = try await postToken(body, contentType: .json, stage: .refresh)
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

    /// 토큰 엔드포인트를 부른 단계. 같은 `postToken`을 쓰지만 오류의 의미가 다르다 —
    /// 인가 코드 교환의 `invalid_grant`(코드 만료·재사용)는 저장된 세션과 무관하고,
    /// refresh의 영구 거부만 저장된 refresh token을 버려야 한다.
    enum Stage { case exchange, refresh }

    /// 상태 코드와 무관하게 refresh token이 되살아날 수 없음을 뜻하는 오류 코드(소문자 비교).
    /// 공식 Codex CLI(`codex-rs/login` `classify_refresh_token_failure`)와 같은 분류다.
    static let permanentRefreshErrorCodes: Set<String> = [
        "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated",
    ]

    /// 토큰 엔드포인트 오류 본문에서 기계 코드를 구조적으로 뽑는다.
    /// 지원 형태(이 순서로 본다): `{"error":"x"}`, `{"error":{"code":"x"}}`, `{"code":"x"}`. JSON이 아니면 nil.
    static func errorCode(in body: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        if let error = json["error"] as? String, !error.isEmpty { return error }
        if let error = json["error"] as? [String: Any], let code = error["code"] as? String, !code.isEmpty {
            return code
        }
        if let code = json["code"] as? String, !code.isEmpty { return code }
        return nil
    }

    /// refresh 응답이 영구 실패(재로그인 필요)인지 — 공식 Codex CLI 규칙:
    /// (1) HTTP 401이면 코드와 무관하게, (2) 영구 코드 3종이면 상태와 무관하게,
    /// (3) HTTP 400 + `invalid_grant`. 코드는 대소문자를 무시한다.
    /// 그 밖(429·5xx·400 invalid_request·미지 코드·잘못된 JSON)은 일시 실패 — 자격증명을 보존한다.
    static func isPermanentRefreshFailure(status: Int, body: Data) -> Bool {
        if status == 401 { return true }
        let code = errorCode(in: body)?.lowercased()
        if let code, permanentRefreshErrorCodes.contains(code) { return true }
        return status == 400 && code == "invalid_grant"
    }

    private static func postToken(_ body: Data, contentType: ContentType,
                                  stage: Stage) async throws -> TokenResponse {
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
        guard (200..<300).contains(status) else { throw tokenError(status: status, body: data, stage: stage) }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw OAuthError.exchangeFailed(L10n(lang: currentLang()).errParse(error.localizedDescription),
                                            code: "parse")
        }
    }

    /// 토큰 엔드포인트 비정상 응답 → 오류(순수 함수 — 테스트 대상).
    /// - refresh: 알려진 영구 오류만 `refreshRevoked`(저장된 refresh token 폐기 대상)로, 나머지는 `refreshFailed`.
    /// - exchange: 기존 동작 유지 — `invalid_grant`(코드 만료·재사용)는 재로그인 안내로, 나머지는 `exchangeFailed`.
    ///   교환 단계 오류는 `TokenStore`를 거치지 않으므로 저장된 다른 세션에 영향을 주지 않는다.
    static func tokenError(status: Int, body: Data, stage: Stage) -> OAuthError {
        let msg = String(data: body, encoding: .utf8) ?? "HTTP \(status)"
        switch stage {
        case .refresh:
            if isPermanentRefreshFailure(status: status, body: body) { return .refreshRevoked }
            return .refreshFailed("HTTP \(status): \(msg)",
                                  code: LoginFailureCode.http(status: status, body: body))
        case .exchange:
            if status == 400 || status == 401, errorCode(in: body) == "invalid_grant" || msg.contains("invalid_grant") {
                return .refreshRevoked
            }
            return .exchangeFailed("HTTP \(status): \(msg)",
                                   code: LoginFailureCode.http(status: status, body: body))
        }
    }

    /// 폼 본문 — `+`가 공백으로 바뀌지 않도록 공용 인코더를 쓴다(`FormURLEncoding`).
    static func form(_ params: [String: String]) -> Data {
        FormURLEncoding.body(params)
    }
}
