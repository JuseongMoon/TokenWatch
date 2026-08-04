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
            throw DeviceFlowError.http(json["error_description"] as? String
                                       ?? L10n(lang: currentLang()).errNotAuthenticated)
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

    /// 승인될 때까지 interval초 간격으로 폴링한다. 만료/거부 시 throw.
    /// Task 취소(화면 이탈) 시 CancellationError를 던진다.
    static func pollForToken(_ device: DeviceCode) async throws -> OAuthTokens {
        var interval = max(device.interval, 1)
        let deadline = Date().addingTimeInterval(TimeInterval(device.expiresIn))

        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            try Task.checkCancellation()

            let body = form([
                "client_id": clientID,
                "device_code": device.deviceCode,
                "grant_type": grantType,
            ])
            let json = try await postForm(tokenURL, body: body)

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
                throw DeviceFlowError.http(json["error_description"] as? String ?? other)
            case .none:
                continue
            }
        }
        throw DeviceFlowError.expired
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
            throw DeviceFlowError.http("HTTP \(status): \(msg)")
        }
        let obj = try JSONSerialization.jsonObject(with: data)
        return (obj as? [String: Any]) ?? [:]
    }

    private static func form(_ params: [String: String]) -> Data {
        var comp = URLComponents()
        comp.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((comp.percentEncodedQuery ?? "").utf8)
    }
}

enum DeviceFlowError: LocalizedError {
    case expired
    case denied
    case http(String)

    var errorDescription: String? {
        let loc = L10n(lang: currentLang())
        switch self {
        case .expired: return loc.deviceFlowExpired
        case .denied:  return loc.deviceFlowDenied
        case .http(let m): return m
        }
    }
}
