//
//  JWT.swift
//  TokenWatch
//
//  id_token(JWT) payload 디코딩 + OpenAI/Codex 클레임 추출.
//  (참고: TokenBar agent_usage.rs jwt_email / jwt_plan)
//

import Foundation

enum JWT {
    /// JWT의 payload(가운데 세그먼트)를 JSON 딕셔너리로 디코드.
    static func payload(_ token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // base64 padding 보정.
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    /// 이메일: `email` 또는 `https://api.openai.com/profile.email`.
    static func email(_ token: String) -> String? {
        guard let p = payload(token) else { return nil }
        if let e = (p["email"] as? String)?.nonEmpty { return e }
        if let profile = p["https://api.openai.com/profile"] as? [String: Any],
           let e = (profile["email"] as? String)?.nonEmpty { return e }
        return nil
    }

    /// 플랜: `chatgpt_plan_type` 또는 `https://api.openai.com/auth.chatgpt_plan_type`.
    static func plan(_ token: String) -> String? {
        guard let p = payload(token) else { return nil }
        if let v = (p["chatgpt_plan_type"] as? String)?.nonEmpty { return v.claudePrettyPlan }
        if let auth = p["https://api.openai.com/auth"] as? [String: Any],
           let v = (auth["chatgpt_plan_type"] as? String)?.nonEmpty { return v.claudePrettyPlan }
        return nil
    }

    /// account_id: `https://api.openai.com/auth.chatgpt_account_id`.
    static func accountID(_ token: String) -> String? {
        guard let p = payload(token) else { return nil }
        if let auth = p["https://api.openai.com/auth"] as? [String: Any],
           let v = (auth["chatgpt_account_id"] as? String)?.nonEmpty { return v }
        return nil
    }
}

private extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// "chatgpt_plus" → "Chatgpt Plus" 형태로 정리(TokenBar clean_plan).
    var claudePrettyPlan: String {
        split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
