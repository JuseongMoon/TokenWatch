//
//  LoginFailureCode.swift
//  TokenWatch
//
//  로그인 실패(`login_fail.code`)의 기계 판독 코드. GA 이벤트와 로그인 실패 진단 보고
//  (LoginFailureReporter)가 같은 값을 쓰고, 서버도 같은 분류표로 받는다 — 값을 바꾸면 양쪽을 함께 고친다.
//  모든 코드는 `^[a-z0-9_]{1,40}$`. 원문 응답 본문·URL·이메일·토큰은 어떤 경로로도 넣지 않는다.
//
//  | 코드 | 뜻 |
//  |------|----|
//  | http_<status> | 토큰·교환·device·poll·키 확인 엔드포인트의 비정상 응답(아래 특정 사유가 아닌 것) |
//  | invalid_grant | OAuth `error: invalid_grant` — 인가 코드 만료·재사용 |
//  | invalid_client | `invalid_client`/`unauthorized_client`(GitHub `incorrect_client_credentials`) — 클라이언트 ID 차단 신호 |
//  | redirect_mismatch | redirect_uri 거부 |
//  | parse | 2xx인데 응답을 해석하지 못했거나 토큰 필드가 없다 — 스키마 변경 신호 |
//  | malformed / unavailable | Cursor auth/poll: 200인데 토큰 없음 / 폴링 경로 자체가 사라짐 |
//  | denied / expired / timed_out | 폴링 로그인 거부 / 코드 만료 / 승인 대기 시간 초과 |
//  | network_offline / network_timeout / network_other | URLError 분류 |
//  | webview_<n> | 로그인 웹뷰 탐색 실패(NSError 코드 절댓값, 예: webview_1009) |
//  | state_mismatch / code_parse / keychain_save | 앱 내부 단계 실패 |
//  | loopback_listen / unsupported_provider / auth_session_start / auth_session_<n> | 인증 시트 흐름 |
//  | other | 위 어디에도 해당하지 않는 에러 |
//

import Foundation

enum LoginFailureCode {
    static let other = "other"

    // MARK: 에러 → 코드

    /// 로그인 흐름에서 잡은 에러를 코드로. 에러가 코드를 이미 들고 있으면 그 값을 쓴다.
    static func from(_ error: Error) -> String {
        switch error {
        case let e as OAuthError:
            switch e {
            case .exchangeFailed(_, let code), .refreshFailed(_, let code): return code ?? other
            case .refreshRevoked: return "invalid_grant"
            case .notAuthenticated: return other
            }
        case let e as DeviceFlowError:
            switch e {
            case .expired: return "expired"
            case .denied: return "denied"
            case .timedOut: return "timed_out"
            case .http(_, let code): return code ?? other
            }
        // Kimi는 두 지역 호스트가 모두 401일 때만 던진다.
        case KimiKeyError.invalid: return "http_401"
        case UsageError.unauthorized: return "http_401"
        case UsageError.rateLimited: return "http_429"
        case UsageError.http(let status, _): return http(status)
        case UsageError.decode, UsageError.noWindows: return "parse"
        case let e as URLError: return network(e)
        case is DecodingError: return "parse"
        default:
            // JSONSerialization 실패(NSCocoaErrorDomain 3840)도 응답 해석 실패다.
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain, ns.code == NSPropertyListReadCorruptError { return "parse" }
            return other
        }
    }

    static func network(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .internationalRoamingOff, .callIsActive:
            return "network_offline"
        case .timedOut:
            return "network_timeout"
        default:
            return "network_other"
        }
    }

    // MARK: HTTP 응답 → 코드

    static func http(_ status: Int) -> String {
        "http_\(max(status, 0))"
    }

    /// 토큰·device 엔드포인트의 비정상 응답. 본문의 OAuth `error` 값으로 특정 사유를 먼저 찾고,
    /// 없으면 `http_<status>`. (본문은 판정에만 쓰고 코드에는 싣지 않는다.)
    static func http(status: Int, body: Data) -> String {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if let error = json?["error"] as? String,
           let code = oauthError(error, description: json?["error_description"] as? String) {
            return code
        }
        // JSON이 아니어도 invalid_grant는 기존 분류(refreshRevoked)와 같은 방식으로 본다.
        if String(decoding: body, as: UTF8.self).contains("invalid_grant") { return "invalid_grant" }
        return http(status)
    }

    /// OAuth(RFC 6749)·GitHub device flow의 `error` 값 → 코드. 특정 사유가 아니면 nil.
    static func oauthError(_ error: String, description: String? = nil) -> String? {
        switch error {
        case "invalid_grant":
            return "invalid_grant"
        case "invalid_client", "unauthorized_client", "incorrect_client_credentials":
            return "invalid_client"
        case "redirect_uri_mismatch":
            return "redirect_mismatch"
        case "invalid_request" where description?.lowercased().contains("redirect") == true:
            return "redirect_mismatch"
        default:
            return nil
        }
    }

    // MARK: 웹뷰

    /// 로그인 웹뷰 탐색 실패. 음수 NSURLError 코드는 절댓값으로 쓴다(`-1009` → `webview_1009`).
    static func webview(_ error: Error) -> String {
        "webview_\(abs((error as NSError).code))"
    }

    // MARK: 정규화

    /// 전송 직전 안전장치 — 소문자·`[a-z0-9_]`만 남기고 40자로 자른다. 비면 `other`.
    static func sanitized(_ code: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_")
        let cleaned = String(code.lowercased().map { allowed.contains($0) ? $0 : "_" }.prefix(40))
        return cleaned.isEmpty ? other : cleaned
    }
}
