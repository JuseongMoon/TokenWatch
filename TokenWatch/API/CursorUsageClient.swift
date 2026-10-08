//
//  CursorUsageClient.swift
//  TokenWatch
//
//  Cursor 구독 사용량: cursor.com 대시보드가 쓰는 `GET /api/usage-summary` → 사용량 창.
//  (참고: CodexBar `CursorStatusProbe`의 응답 모델, 실측 샘플은 KyleBing/m5stack-cardputer-sparks `api/cursor`.)
//
//  2026-02부터 개인 플랜은 결제 주기(월)마다 리셋되는 풀 두 개다 — Cursor Models(`autoPercentUsed`)와
//  Other Models(`apiPercentUsed`). 퍼센트는 이미 %(0.36 = 0.36%)이고 금액은 센트다.
//  `totalPercentUsed`는 대시보드와 어긋난 사례가 있어 쓰지 않는다.
//
//  ⚠️ 공식 API가 아니다. 형식이 자주 바뀌므로(2026년에만 여러 번) 필수 필드가 없으면 0%로 보이지 않고
//     오류로 처리한다. 세션이 없거나 만료되면 401이다(실측).
//

import Foundation

enum CursorUsageClient {
    static let summaryURL = "https://cursor.com/api/usage-summary"

    static func fetch(tokens: OAuthTokens) async throws -> [UsageWindow] {
        try await fetchUsage(tokens: tokens).windows
    }

    /// 사용량 창과 플랜 라벨(`membershipType`).
    static func fetchUsage(tokens: OAuthTokens) async throws -> (windows: [UsageWindow], plan: String?) {
        guard let cookie = CursorAuth.cookieHeader(for: tokens) else { throw UsageError.unauthorized }
        var req = URLRequest(url: URL(string: summaryURL)!)
        req.httpMethod = "GET"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("TokenWatch/1.0", forHTTPHeaderField: "User-Agent")
        req.httpShouldHandleCookies = false

        // 리다이렉트는 따라가지 않는다 — 세션 쿠키가 다른 주소로 따라 나가지 않게.
        let (data, response) = try await APISession.shared.data(for: req, delegate: NoRedirectTaskDelegate())
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        // 로그인 페이지로 보내는 3xx도 세션이 없다는 뜻이다.
        if status == 401 || status == 403 || (300..<400).contains(status) { throw UsageError.unauthorized }
        if status == 429 {
            throw UsageError.rateLimited(parseRetryAfter(http?.value(forHTTPHeaderField: "Retry-After")))
        }
        guard (200..<300).contains(status) else {
            throw UsageError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return try CursorUsageMapper.usage(from: data)
    }
}

/// 리다이렉트를 따라가지 않는 태스크 델리게이트.
/// (async 버전의 이 델리게이트 메서드는 Swift 6.3 컴파일러가 크래시한 이력이 있어 completion 버전을 쓴다.)
nonisolated final class NoRedirectTaskDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - 응답 모델

/// `usage-summary` 응답 중 창을 만드는 데 쓰는 부분만 받는다(on-demand·팀 사용량은 v1에서 쓰지 않음).
struct CursorUsageSummary: Decodable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let membershipType: String?
    let individualUsage: IndividualUsage?

    struct IndividualUsage: Decodable {
        let plan: Plan?
    }

    /// 금액은 센트, 퍼센트는 이미 %.
    struct Plan: Decodable {
        let used: Double?
        let limit: Double?
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
    }
}

// MARK: - 응답 → 창 매핑

enum CursorUsageMapper {
    static let cursorModelsLabel = "Cursor models"
    static let otherModelsLabel = "Other models"
    static let includedLabel = "Included usage"

    static func usage(from data: Data) throws -> (windows: [UsageWindow], plan: String?) {
        let summary: CursorUsageSummary
        do {
            summary = try JSONDecoder().decode(CursorUsageSummary.self, from: data)
        } catch {
            throw UsageError.decode(error.localizedDescription)
        }
        return try usage(from: summary)
    }

    static func usage(from summary: CursorUsageSummary) throws -> (windows: [UsageWindow], plan: String?) {
        // 세션이 없으면 401이 오므로, 200인데 결제 주기·플랜 사용량이 없으면 형식이 바뀐 것이다.
        guard let end = summary.billingCycleEnd.flatMap({ ISO8601DateFormatter.tokenwatchDate(from: $0) }),
              let plan = summary.individualUsage?.plan
        else { throw UsageError.decode("unexpected Cursor usage summary") }

        let start = summary.billingCycleStart.flatMap { ISO8601DateFormatter.tokenwatchDate(from: $0) }
        var seconds: TimeInterval?
        if let start, end > start {
            seconds = end.timeIntervalSince(start)
        }
        func window(_ label: String, _ percent: Double) -> UsageWindow {
            UsageWindow(label: label, usedPercent: min(max(percent, 0), 100), resetsAt: end,
                        kind: .weekly, windowSeconds: seconds)
        }

        var windows: [UsageWindow] = []
        if let auto = plan.autoPercentUsed, auto.isFinite {
            windows.append(window(cursorModelsLabel, auto))
        }
        if let api = plan.apiPercentUsed, api.isFinite {
            windows.append(window(otherModelsLabel, api))
        }
        // 풀 퍼센트가 없는 응답(구형 형식)은 포함 사용량 금액으로 한 창을 만든다.
        if windows.isEmpty, let limit = plan.limit, limit > 0, let used = plan.used, used >= 0 {
            windows.append(window(includedLabel, used / limit * 100))
        }
        return (windows, planLabel(summary.membershipType))
    }

    /// `membershipType` → 표시용 플랜 이름(터미널 크롬이라 번역하지 않는다).
    static func planLabel(_ membershipType: String?) -> String? {
        guard let raw = membershipType?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        switch raw.lowercased() {
        case "free", "hobby": return "Hobby"
        case "free_trial": return "Pro Trial"
        case "pro": return "Pro"
        case "pro_student": return "Pro Student"
        case "pro_plus": return "Pro Plus"
        case "ultra": return "Ultra"
        case "express": return "Start"
        case "team", "business": return "Teams"
        case "enterprise": return "Enterprise"
        default:
            return raw.split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }
}
