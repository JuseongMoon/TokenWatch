//
//  CodexAccountClient.swift
//  TokenWatch
//
//  Codex(ChatGPT) 계정의 현재 plan을 라이브로 조회한다.
//  id_token(JWT)의 chatgpt_plan_type은 최초 로그인 시점 값에 고정되어 refresh로도
//  갱신되지 않는다(실증됨: refresh가 새 id_token을 줘도 plan 클레임은 그대로).
//  따라서 Pro→Free 같은 실제 plan 변경은 이 accounts/check 엔드포인트에서 읽어야 최신이다.
//  access token은 정상 갱신되고, 이 엔드포인트는 서버의 현재 plan 상태를 반환한다.
//

import Foundation

enum CodexAccountClient {
    static let accountsCheckURL = "https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27"

    /// 현재 plan(정리된 문자열, 예: "Free"/"Plus"/"Pro")을 반환. 실패 시 nil.
    static func fetchPlan(tokens: OAuthTokens) async throws -> String? {
        var req = URLRequest(url: URL(string: accountsCheckURL)!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("TokenWatch/1.0", forHTTPHeaderField: "User-Agent")
        if let accountId = tokens.accountId, !accountId.isEmpty {
            req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await APISession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401 || status == 403 { throw UsageError.unauthorized }
            throw UsageError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return rawPlanType(from: data, preferredAccountId: tokens.accountId)?.prettyPlan
    }

    /// accounts/check 응답에서 plan_type 추출. account_id 우선, 없으면 순서/임의 계정.
    /// 응답 구조: { accounts: { "<id>": { account: { plan_type, ... } } }, account_ordering: [...] }
    private static func rawPlanType(from data: Data, preferredAccountId: String?) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = root["accounts"] as? [String: Any] else { return nil }
        let orderedIds = root["account_ordering"] as? [String] ?? []
        let candidates = [preferredAccountId].compactMap { $0?.nonEmpty } + orderedIds + Array(accounts.keys)
        for id in candidates {
            if let plan = planType(in: accounts[id]) { return plan }
        }
        // 후보로 못 찾으면 임의 계정 스캔.
        for (_, v) in accounts {
            if let plan = planType(in: v) { return plan }
        }
        return nil
    }

    private static func planType(in accountEntry: Any?) -> String? {
        guard let entry = accountEntry as? [String: Any],
              let acc = entry["account"] as? [String: Any] else { return nil }
        return (acc["plan_type"] as? String)?.nonEmpty
    }
}

private extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// "chatgpt_plus" → "Chatgpt Plus", "free" → "Free" (JWT.plan과 동일 규칙).
    var prettyPlan: String {
        split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
