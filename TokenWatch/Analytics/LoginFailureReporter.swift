//
//  LoginFailureReporter.swift
//  TokenWatch
//
//  로그인 실패 진단 보고 — provider 쪽 로그인 정책 변경(클라이언트 차단·redirect 변경·스키마 변경)을
//  스토어 리뷰보다 먼저 알기 위해, login_fail과 같은 내용을 개발자 서버(텔레그램 알림)로 한 번 보낸다.
//  실린 값은 플랫폼·앱 버전·빌드·provider·인증 방식·단계·코드뿐이다. 기기·계정 식별자, 이메일,
//  토큰, 원문 에러는 싣지 않는다. 게이트(옵트아웃·데모·DEBUG)는 AnalyticsService가 판정한 뒤 부른다.
//  보내고 잊는다 — 결과·오류는 무시하고 재시도하지 않는다.
//

import Foundation

enum LoginFailureReporter {
    static let endpoint = URL(string: "https://us-central1-footagemanager-41ad8.cloudfunctions.net/bot02LoginFailureReport")!

    /// 서버 계약과 1:1 — 키를 더하면 서버가 400으로 거절한다.
    struct Payload: Encodable, Equatable {
        let platform: String
        let appVersion: String
        let build: String
        let provider: String
        let authKind: String
        let stage: String
        let code: String
    }

    /// 자격증명과 무관한 1회성 요청이라 쿠키·캐시를 남기지 않는 별도 ephemeral 세션을 쓴다.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        return URLSession(configuration: config)
    }()

    static func report(provider: AgentProvider, stage: LoginStage, code: String) {
        guard let payload = payload(provider: provider, stage: stage, code: code,
                                    info: Bundle.main.infoDictionary ?? [:]),
              let body = try? JSONEncoder().encode(payload)
        else { return }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        session.dataTask(with: req).resume()
    }

    /// 보낼 본문. 버전 문자열이 서버 규칙(`^[0-9A-Za-z][0-9A-Za-z.\-]{0,19}$`)에 맞지 않으면 nil(보내지 않는다).
    static func payload(provider: AgentProvider, stage: LoginStage, code: String,
                        info: [String: Any]) -> Payload? {
        guard let version = info["CFBundleShortVersionString"] as? String, isValidVersion(version),
              let build = info["CFBundleVersion"] as? String, isValidVersion(build)
        else { return nil }
        return Payload(platform: "ios", appVersion: version, build: build,
                       provider: provider.rawValue,
                       authKind: AnalyticsEvent.authKindTag(provider),
                       stage: stage.rawValue,
                       code: LoginFailureCode.sanitized(code))
    }

    static func isValidVersion(_ text: String) -> Bool {
        text.range(of: #"\A[0-9A-Za-z][0-9A-Za-z.\-]{0,19}\z"#, options: .regularExpression) != nil
    }
}
