//
//  CursorAuth.swift
//  TokenWatch
//
//  Cursor 로그인 — Cursor 공식 SDK·CLI와 같은 "로그인 페이지 승인 + 폴링".
//
//  흐름(`@cursor/sdk` 1.0.31의 login-flow와 같다):
//   1. verifier(32바이트 base64url), challenge(= base64url(SHA-256(verifier 문자열))), uuid를 만든다.
//   2. `cursor.com/loginDeepControl?challenge&uuid&mode=login&redirectTarget=cli`를 앱 안 Safari View로 연다.
//      페이지는 승인 결과를 앱으로 돌려보내지 않는다(콜백 없음).
//   3. `api2.cursor.sh/auth/poll`을 폴링한다 — 대기 중에는 404 `Not found`, 승인되면 200 `{accessToken, refreshToken}`.
//      POST(JSON 본문)가 기본이고, POST 경로가 없는 서버(404 본문이 `Not found`가 아님)면 GET으로 한 번 전환한다.
//
//  ⚠️ 공식 사용량 API가 아니다. 사용량은 cursor.com 대시보드가 쓰는 `api/usage-summary`를 세션 쿠키로
//     읽는다(`CursorUsageClient`). v1은 refresh를 하지 않는다 — 토큰(약 60일)이 만료되면 다시 로그인한다.
//     그래서 refresh token은 저장하지 않는다.
//

import Foundation

enum CursorAuth {
    // MARK: 설정 상수 (검증 대상)
    static let loginURL = "https://cursor.com/loginDeepControl"
    static let pollURL = "https://api2.cursor.sh/auth/poll"
    static let meURL = "https://cursor.com/api/auth/me"
    /// 로그인 페이지에 "무엇에 로그인하는지"로 표시되는 값. CLI 토큰으로 usage-summary가 되는 실사례를 따른다.
    static let redirectTarget = "cli"

    /// 폴링 한도 — SDK 기본값(최대 150회, 1초에서 1.2배씩 늘려 10초 상한, 약 20분).
    static let maxPollAttempts = 150
    static let pollBaseDelay: TimeInterval = 1
    static let pollMaxDelay: TimeInterval = 10

    /// 로그인 한 번의 비밀값과 로그인 페이지 주소.
    struct Handshake: Sendable, Equatable {
        let uuid: String
        /// 이 앱이 로그인을 시작했음을 증명하는 값. `auth/poll` 외에는 내보내지 않는다.
        let verifier: String
        let loginURL: URL
    }

    static func makeHandshake(pkce: PKCE = PKCE(), uuid: String = UUID().uuidString.lowercased()) -> Handshake {
        var comp = URLComponents(string: loginURL)!
        comp.queryItems = [
            .init(name: "challenge", value: pkce.challenge),
            .init(name: "uuid", value: uuid),
            .init(name: "mode", value: "login"),
            .init(name: "redirectTarget", value: redirectTarget),
        ]
        return Handshake(uuid: uuid, verifier: pkce.verifier, loginURL: comp.url!)
    }

    // MARK: 로그인 완료

    /// 승인될 때까지 폴링해 저장용 자격증명을 만든다(이메일은 `auth/me`로 채운다).
    static func completeLogin(_ handshake: Handshake) async throws -> OAuthTokens {
        let accessToken = try await pollForAccessToken(handshake)
        guard let id = userID(fromJWT: accessToken) else {
            throw DeviceFlowError.http(L10n(lang: currentLang()).errParse("Cursor token"), code: "parse")
        }
        // 이메일은 카드 라벨·중복 방지용 부가 정보라 실패해도 로그인은 끝낸다.
        let email = try? await fetchEmail(accessToken: accessToken, userID: id)
        return credential(accessToken: accessToken, userID: id, email: email ?? nil)
    }

    /// 저장용 자격증명. refresh token은 담지 않고(v1), 만료는 JWT `exp`, 사용자 id는 `accountId`에 둔다.
    static func credential(accessToken: String, userID: String, email: String?) -> OAuthTokens {
        OAuthTokens(accessToken: accessToken, refreshToken: nil,
                    expiresAt: expiry(fromJWT: accessToken), scopes: [],
                    accountEmail: email, plan: nil, idToken: nil, accountId: userID)
    }

    // MARK: 폴링

    /// 대기(404) 동안 백오프하며 기다린다. 승인되면 access token, 거부·경로 없음·연속 오류·시간 초과면 throw.
    static func pollForAccessToken(_ handshake: Handshake) async throws -> String {
        var useGET = false
        var checkedPendingBody = false
        var consecutiveErrors = 0
        for attempt in 0..<maxPollAttempts {
            try Task.checkCancellation()
            let delay = min(pollBaseDelay * pow(1.2, Double(attempt)), pollMaxDelay)

            let data: Data
            let status: Int
            do {
                let (body, response) = try await APISession.shared.data(for: pollRequest(handshake, useGET: useGET))
                data = body
                status = (response as? HTTPURLResponse)?.statusCode ?? 0
            } catch let error as URLError where error.code != .cancelled {
                // 몇 분 동안 도는 폴링이라 한 번 끊겼다고 처음부터 다시 시키지 않는다.
                consecutiveErrors += 1
                if consecutiveErrors >= 3 { throw error }
                try await Task.sleep(for: .seconds(delay))
                continue
            }

            switch pollOutcome(status: status, body: data, usingGET: useGET,
                               checkedPendingBody: checkedPendingBody) {
            case .tokens(let accessToken):
                return accessToken
            case .pending:
                checkedPendingBody = true
                consecutiveErrors = 0
                try await Task.sleep(for: .seconds(delay))
            case .switchToGET:
                useGET = true
            case .unavailable:
                throw DeviceFlowError.http("Cursor auth/poll unavailable", code: "unavailable")
            case .denied:
                throw DeviceFlowError.denied
            case .malformed:
                throw DeviceFlowError.http(L10n(lang: currentLang()).errParse("Cursor auth/poll"), code: "malformed")
            case .retry:
                consecutiveErrors += 1
                if consecutiveErrors >= 3 {
                    throw DeviceFlowError.http("HTTP \(status)", code: LoginFailureCode.http(status))
                }
                try await Task.sleep(for: .seconds(delay))
            }
        }
        throw DeviceFlowError.timedOut
    }

    enum PollOutcome: Equatable {
        case tokens(String)
        /// 아직 승인 전(404).
        case pending
        /// POST 경로가 없는 서버 — 이후로는 GET으로 묻는다.
        case switchToGET
        /// GET 경로도 없다.
        case unavailable
        /// 로그인이 거부·만료됐다.
        case denied
        /// 200인데 토큰이 없다.
        case malformed
        /// 일시 오류 — 다시 묻는다.
        case retry
    }

    /// `auth/poll` 응답 한 건의 판정(순수 함수). SDK `pollForLoginTokens`의 규칙을 따른다.
    static func pollOutcome(status: Int, body: Data, usingGET: Bool, checkedPendingBody: Bool) -> PollOutcome {
        switch status {
        case 404:
            if checkedPendingBody { return .pending }
            let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !usingGET && text != "Not found" { return .switchToGET }
            if usingGET && isRouteNotFound(text) { return .unavailable }
            return .pending
        case 200..<300:
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let accessToken = json["accessToken"] as? String, !accessToken.isEmpty,
                  json["refreshToken"] is String
            else { return .malformed }
            return .tokens(accessToken)
        case 400, 401, 403, 410:
            return .denied
        default:
            return .retry
        }
    }

    /// 경로 자체가 없다는 404 본문(`{"message":"Route GET:/auth/poll not found"}` 형태).
    static func isRouteNotFound(_ text: String) -> Bool {
        guard text.hasPrefix("{"),
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let message = json["message"] as? String
        else { return false }
        return message.hasPrefix("Route ") && message.contains("not found")
    }

    /// POST는 verifier를 본문에 싣는다(주소·서버 접근 로그에 남지 않게). GET 폴백만 쿼리로 보낸다.
    static func pollRequest(_ handshake: Handshake, useGET: Bool) -> URLRequest {
        var req: URLRequest
        if useGET {
            var comp = URLComponents(string: pollURL)!
            comp.queryItems = [
                .init(name: "uuid", value: handshake.uuid),
                .init(name: "verifier", value: handshake.verifier),
            ]
            req = URLRequest(url: comp.url!)
            req.httpMethod = "GET"
        } else {
            req = URLRequest(url: URL(string: pollURL)!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "uuid": handshake.uuid, "verifier": handshake.verifier,
            ])
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        return req
    }

    // MARK: 계정 이메일

    /// 로그인 직후 계정 이메일(카드 라벨·중복 방지용). 세션이 인정되지 않으면 204라 nil.
    static func fetchEmail(accessToken: String, userID: String) async throws -> String? {
        var req = URLRequest(url: URL(string: meURL)!)
        req.httpMethod = "GET"
        req.setValue(cookieHeader(userID: userID, accessToken: accessToken), forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpShouldHandleCookies = false
        let (data, response) = try await APISession.shared.data(for: req, delegate: NoRedirectTaskDelegate())
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = (json["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty
        else { return nil }
        return email
    }

    // MARK: 세션 쿠키 · JWT

    /// cursor.com 대시보드 API가 받는 세션 쿠키. 토큰만 담거나 Bearer로 보내면 401이다(사용자 id와 쌍이어야 한다).
    static func cookieHeader(userID: String, accessToken: String) -> String {
        "WorkosCursorSessionToken=\(userID)%3A%3A\(accessToken)"
    }

    /// 저장된 자격증명으로 쿠키를 만든다. 사용자 id는 저장값, 없으면 JWT `sub`에서 다시 뽑는다.
    static func cookieHeader(for tokens: OAuthTokens) -> String? {
        guard let id = tokens.accountId ?? userID(fromJWT: tokens.accessToken) else { return nil }
        return cookieHeader(userID: id, accessToken: tokens.accessToken)
    }

    /// JWT `sub`(예: `auth0|user_01ABC`)의 마지막 `|` 뒤가 쿠키에 쓰는 사용자 id다.
    static func userID(fromJWT token: String) -> String? {
        guard let sub = JWT.payload(token)?["sub"] as? String,
              let last = sub.split(separator: "|").last
        else { return nil }
        let id = String(last).trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? nil : id
    }

    /// JWT `exp`(초) → 만료 시각. 없으면 nil(만료를 모르면 401이 날 때 재로그인을 안내한다).
    static func expiry(fromJWT token: String) -> Date? {
        guard let exp = JWT.payload(token)?["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
