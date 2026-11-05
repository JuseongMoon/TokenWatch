//
//  CopilotDeviceFlow.swift
//  TokenWatch
//
//  GitHub Copilot 로그인 — OAuth 2.0 Device Authorization Grant.
//  (1) device/code로 user_code 발급 → (2) 사용자가 브라우저에서 승인 →
//  (3) access_token 폴링. 발급된 GitHub OAuth 토큰으로 copilot_internal/user를 호출한다.
//
//  ⚠️ clientID는 VS Code/Copilot CLI가 쓰는 레거시 OAuth App id(read:user 스코프)로,
//     이 토큰이 copilot_internal 엔드포인트에서 동작한다. 실제 로그인으로 검증하며
//     필요 시 아래 상수만 조정한다.
//

import Foundation

enum CopilotDeviceFlow {
    // MARK: 설정 상수 (검증 대상)
    static let clientID = "Iv1.b507a08c87ecfe98"
    static let deviceCodeURL = "https://github.com/login/device/code"
    static let tokenURL = "https://github.com/login/oauth/access_token"
    static let scope = "read:user"
    static let grantType = "urn:ietf:params:oauth:grant-type:device_code"

    /// device/code 응답.
    struct DeviceCode: Sendable {
        let deviceCode: String
        let userCode: String
        let verificationURI: URL?
        let interval: Int
        let expiresIn: Int
    }

    // MARK: Step 1 — device code 요청

    static func requestDeviceCode() async throws -> DeviceCode {
        let body = form(["client_id": clientID, "scope": scope])
        let json = try await postForm(deviceCodeURL, body: body)
        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String else {
            // GitHub은 거부도 200 + `error`로 준다(device flow 비활성화·클라이언트 거부 등).
            let code = (json["error"] as? String).map {
                LoginFailureCode.oauthError($0) ?? LoginFailureCode.http(200)
            } ?? "parse"
            throw DeviceFlowError.http(json["error_description"] as? String
                                       ?? L10n(lang: currentLang()).errNotAuthenticated, code: code)
        }
        let uri = (json["verification_uri"] as? String) ?? "https://github.com/login/device"
        return DeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: URL(string: uri),
            interval: (json["interval"] as? Int) ?? 5,
            expiresIn: (json["expires_in"] as? Int) ?? 900
        )
    }

    // MARK: Step 3 — access_token 폴링

    /// 폴링 한 번의 요청 — 테스트는 가짜 응답·오류를 넣는다.
    typealias PollRequest = @Sendable () async throws -> [String: Any]
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    /// 승인될 때까지 interval초 간격으로 폴링한다. 만료/거부 시 throw.
    /// Task 취소(화면 이탈) 시 CancellationError를 던진다.
    ///
    /// 일시 네트워크 오류(`PollingNetwork.isTransient`)는 실패로 끝내지 않고 다음 주기에 다시 묻는다 —
    /// 승인하는 동안 앱이 백그라운드로 갔다 돌아오면 첫 요청이 끊기기 쉽다. 끝내는 조건은
    /// `expired_token`·`access_denied`·device code 만료(`expires_in`)뿐이다.
    /// - Parameters:
    ///   - sleep: 주기 대기. 앱이 다시 활성화되면 깨어나는 `PollWaker.sleep`을 넘길 수 있다.
    ///   - now: 만료 판정 시계(테스트 주입용).
    ///   - request: 토큰 요청(테스트 주입용). nil이면 GitHub에 실제로 묻는다.
    static func pollForToken(_ device: DeviceCode,
                             sleep: Sleeper? = nil,
                             now: (@Sendable () -> Date)? = nil,
                             request: PollRequest? = nil) async throws -> OAuthTokens {
        let sleep = sleep ?? { try await Task.sleep(for: $0) }
        let now = now ?? { Date() }
        let body = form([
            "client_id": clientID,
            "device_code": device.deviceCode,
            "grant_type": grantType,
        ])
        let request = request ?? { try await postForm(tokenURL, body: body) }

        var interval = max(device.interval, 1)
        let deadline = now().addingTimeInterval(TimeInterval(device.expiresIn))

        while now() < deadline {
            try await sleep(.seconds(interval))
            try Task.checkCancellation()

            let json: [String: Any]
            do {
                json = try await request()
            } catch let error as URLError where PollingNetwork.isTransient(error) {
                continue   // 다음 주기에 다시 묻는다
            }

            if let token = json["access_token"] as? String, !token.isEmpty {
                // GitHub device flow 토큰은 만료/refresh가 없어 그대로 담는다.
                return OAuthTokens(accessToken: token, refreshToken: nil,
                                   expiresAt: nil, scopes: [],
                                   accountEmail: nil, plan: nil)
            }
            switch json["error"] as? String {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
            case "expired_token":
                throw DeviceFlowError.expired
            case "access_denied":
                throw DeviceFlowError.denied
            case .some(let other):
                throw DeviceFlowError.http(json["error_description"] as? String ?? other,
                                           code: LoginFailureCode.oauthError(other) ?? LoginFailureCode.http(200))
            case .none:
                continue
            }
        }
        throw DeviceFlowError.expired
    }

    // MARK: 계정 식별 (같은 계정 재로그인 판별)

    static let authenticatedUserURL = "https://api.github.com/user"

    /// 발급 토큰으로 GitHub 사용자 숫자 ID를 읽는다(공식 REST `GET /user`, 이 앱이 이미 받는 `read:user`
    /// 범위로 충분하다 — 추가 권한을 요청하지 않는다). 이 ID는 사용자명·이메일이 바뀌거나 비공개여도
    /// 그대로라 카드 매칭 키로 쓴다. 표시·분석에는 쓰지 않는다.
    static func fetchUserID(accessToken: String) async throws -> String {
        var req = URLRequest(url: URL(string: authenticatedUserURL)!)
        req.httpMethod = "GET"
        req.setValue("token \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await APISession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw DeviceFlowError.http(L10n(lang: currentLang()).copilotIdentityFailed,
                                       code: LoginFailureCode.http(status))
        }
        guard let id = parseUserID(data) else {
            throw DeviceFlowError.http(L10n(lang: currentLang()).copilotIdentityFailed, code: "parse")
        }
        return id
    }

    /// `GET /user` 응답에서 숫자 `id`를 문자열로(순수 함수 — 테스트 대상). 없거나 0 이하면 nil.
    nonisolated static func parseUserID(_ data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let number = json["id"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.int64Value > 0, number.doubleValue == Double(number.int64Value)
        else { return nil }
        return String(number.int64Value)
    }

    /// 폴링으로 받은 토큰에 계정 ID를 붙인다. 식별에 실패하면 로그인을 실패로 돌린다 —
    /// ID 없이 저장하면 같은 계정인지 알 수 없어 중복 카드가 생기기 때문이다(다시 시도하면 된다).
    /// 승인 직후는 앱이 막 전면으로 돌아온 때라 일시 네트워크 오류가 잦다 — 그런 오류는 짧게
    /// 몇 번 다시 시도하고(1초, 2초 간격), 계속 실패할 때만 끝낸다.
    static func identified(_ tokens: OAuthTokens,
                           sleep: Sleeper? = nil,
                           fetch: (@Sendable (String) async throws -> String)? = nil) async throws -> OAuthTokens {
        let sleep = sleep ?? { try await Task.sleep(for: $0) }
        let fetch = fetch ?? { try await fetchUserID(accessToken: $0) }
        let maxAttempts = 3
        var attempt = 1
        while true {
            do {
                var t = tokens
                t.stableUserID = try await fetch(tokens.accessToken)
                return t
            } catch let error as URLError where PollingNetwork.isTransient(error) && attempt < maxAttempts {
                try await sleep(.seconds(attempt))
                attempt += 1
            }
        }
    }

    // MARK: 내부

    private static func postForm(_ urlString: String, body: Data) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: urlString)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = body

        let (data, response) = try await APISession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            throw DeviceFlowError.http("HTTP \(status): \(msg)",
                                       code: LoginFailureCode.http(status: status, body: data))
        }
        // 해석 실패(NSCocoaErrorDomain 3840)는 LoginFailureCode가 `parse`로 분류한다.
        let obj = try JSONSerialization.jsonObject(with: data)
        return (obj as? [String: Any]) ?? [:]
    }

    /// 폼 본문 — `+`가 공백으로 바뀌지 않도록 공용 인코더를 쓴다(`FormURLEncoding`).
    static func form(_ params: [String: String]) -> Data {
        FormURLEncoding.body(params)
    }
}

enum DeviceFlowError: LocalizedError {
    case expired
    case denied
    /// 코드 없는 폴링 로그인(Cursor)이 승인을 기다리다 시간이 다 됐다.
    case timedOut
    /// `code`는 로그인 실패 분석용 기계 코드(`LoginFailureCode`). 표시 문구에는 쓰지 않는다.
    case http(String, code: String? = nil)

    var errorDescription: String? {
        let loc = L10n(lang: currentLang())
        switch self {
        case .expired: return loc.deviceFlowExpired
        case .denied:  return loc.deviceFlowDenied
        case .timedOut: return loc.pollingLoginTimedOut
        case .http(let m, _): return m
        }
    }
}
