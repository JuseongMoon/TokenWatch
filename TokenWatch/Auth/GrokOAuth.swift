//
//  GrokOAuth.swift
//  TokenWatch
//
//  Grok(xAI) OAuth (PKCE) 로그인 / 토큰 교환 / 갱신.
//
//  ⚠️ 상수와 흐름은 xAI 공식 Grok CLI(github.com/xai-org/grok-build의 `xai-grok-login`) 기본 로그인을
//     따른다: auth.x.ai 인가코드 + PKCE, 루프백 `http://127.0.0.1:PORT/callback`(포트는 매번 임의).
//     secret 없는 공개 클라이언트다. CLI와 다른 점 두 가지:
//      - 스코프는 사용량 조회에 필요한 최소 세트만 요청한다(CLI는 대화·워크스페이스 쓰기 권한까지 받는다).
//        실기기에서 조회가 거부되면 CLI 기본 세트로 넓힌다.
//      - CLI가 authorize에 붙이는 분석 집계용 `referrer=grok-build`는 보내지 않는다.
//
//  refresh token은 갱신할 때마다 회전한다(옛 토큰 재사용 → invalid_grant). 그래서 refresh는
//  재시도하지 않고, 갱신 합치기·저장은 `TokenStore`가 맡는다.
//

import Foundation

enum GrokOAuth {
    // MARK: 설정 상수 (검증 대상)
    static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let authorizeURL = "https://auth.x.ai/oauth2/authorize"
    static let tokenURL = "https://auth.x.ai/oauth2/token"
    /// `grok-cli:access`가 사용량 엔드포인트(cli-chat-proxy.grok.com) 호출 권한이다.
    static let scopes = ["openid", "profile", "email", "offline_access", "grok-cli:access"]

    /// 인증 시트 로그인의 루프백 콜백(Grok CLI와 같은 형식). 앱이 띄운 `LoopbackCallbackServer`가 받는다.
    static func loopbackRedirectURI(port: UInt16) -> String {
        "http://127.0.0.1:\(port)/callback"
    }

    // MARK: authorize URL

    static func authorizeURL(pkce: PKCE, redirect: String) -> URL {
        var comp = URLComponents(string: authorizeURL)!
        comp.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: pkce.state),
            // OIDC nonce — CLI처럼 요청마다 새로 만든다(id_token은 표시용 이메일만 읽고 검증하지 않는다).
            .init(name: "nonce", value: UUID().uuidString),
        ]
        return comp.url!
    }

    // MARK: 토큰 교환 / 갱신

    /// - Parameter redirect: authorize에 쓴 루프백 redirect_uri와 같아야 한다(OAuth 규약).
    static func exchange(code: String, pkce: PKCE, redirect: String) async throws -> OAuthTokens {
        let body = formBody([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirect),
            ("client_id", clientID),
            ("code_verifier", pkce.verifier),
        ])
        do {
            let data = try await postTokenRetryingTransientFailure(body)
            return try tokens(from: data, previous: nil)
        } catch let error as OAuthError {
            switch error {
            // 교환 단계의 invalid_grant는 "코드 만료/재사용"이다 — 재로그인 안내 대신 코드 문구로.
            case .refreshRevoked:
                throw OAuthError.exchangeFailed(L10n(lang: currentLang()).errCodeExpired, code: "invalid_grant")
            case .refreshFailed(let message, let code): throw OAuthError.exchangeFailed(message, code: code)
            default: throw error
            }
        }
    }

    static func refresh(tokens previous: OAuthTokens) async throws -> OAuthTokens {
        guard let refreshToken = previous.refreshToken else { throw OAuthError.notAuthenticated }
        let body = formBody([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
        ])
        let data = try await postToken(body)
        return try tokens(from: data, previous: previous)
    }

    // MARK: 응답 해석 (순수 함수 — 테스트에서 직접 검증한다)

    struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
        let expires_in: Int?
        let scope: String?
    }

    /// 토큰 응답 → 저장용 자격증명. 갱신 응답에 새 refresh_token·id_token이 비어 있으면 이전 값을 유지한다.
    /// 플랜은 토큰에 없어서 이전 값을 넘기고, 사용량 응답이 올 때 갱신된다.
    static func tokens(from data: Data, previous: OAuthTokens?, now: Date = Date()) throws -> OAuthTokens {
        let response: TokenResponse
        do {
            response = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw OAuthError.refreshFailed(L10n(lang: currentLang()).errParse(error.localizedDescription),
                                           code: "parse")
        }
        guard !response.access_token.isEmpty else {
            throw OAuthError.refreshFailed("empty access_token", code: "parse")
        }
        let refreshToken = response.refresh_token.flatMap { $0.isEmpty ? nil : $0 } ?? previous?.refreshToken
        let idToken = response.id_token.flatMap { $0.isEmpty ? nil : $0 } ?? previous?.idToken
        return OAuthTokens(
            accessToken: response.access_token,
            refreshToken: refreshToken,
            expiresAt: response.expires_in.map { now.addingTimeInterval(TimeInterval($0)) },
            scopes: response.scope.map { $0.split(separator: " ").map(String.init) } ?? scopes,
            accountEmail: idToken.flatMap { JWT.email($0) } ?? previous?.accountEmail,
            plan: previous?.plan,
            idToken: idToken
        )
    }

    /// 토큰 엔드포인트 오류 분류. 400/401 + invalid_grant는 재시도로 복구되지 않는 거부(재로그인 필요)다.
    static func tokenError(status: Int, body: Data) -> OAuthError {
        let message = String(data: body, encoding: .utf8) ?? ""
        if status == 400 || status == 401, message.contains("invalid_grant") {
            return .refreshRevoked
        }
        return .refreshFailed("HTTP \(status): \(message)", code: LoginFailureCode.http(status: status, body: body))
    }

    /// `application/x-www-form-urlencoded` 본문. `A-Za-z0-9-._~`만 그대로 두고 나머지는 전부 퍼센트 인코딩한다.
    /// (`URLComponents`는 `+`를 그대로 두는데, 폼 디코더는 `+`를 공백으로 읽어 토큰 값이 바뀐다.)
    static func formBody(_ params: [(String, String)]) -> Data {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
        }
        let pairs = params.map { "\(encode($0.0))=\(encode($0.1))" }
        return Data(pairs.joined(separator: "&").utf8)
    }

    // MARK: 네트워크

    /// 교환 전용: 백그라운드에서 막 깨어난 직후처럼 요청이 서버에 닿기 전에 끊긴 일시 오류는
    /// 인가 코드가 아직 유효하므로 한 번 더 보낸다. (refresh에는 쓰지 않는다 — 서버에 닿았다면
    /// refresh token이 이미 회전돼 재전송이 자격증명을 죽일 수 있다.)
    private static func postTokenRetryingTransientFailure(_ body: Data) async throws -> Data {
        do {
            return try await postToken(body)
        } catch let error as URLError where ClaudeOAuth.isTransient(error) {
            try await Task.sleep(for: .seconds(1))
            return try await postToken(body)
        }
    }

    private static func postToken(_ body: Data) async throws -> Data {
        var req = URLRequest(url: URL(string: tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = body

        let (data, response) = try await APISession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw tokenError(status: status, body: data) }
        return data
    }
}
