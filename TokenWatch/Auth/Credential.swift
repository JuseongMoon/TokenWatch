//
//  Credential.swift
//  TokenWatch
//
//  저장되는 자격증명(`OAuthTokens`)을 OAuth 외 방식으로도 만드는 팩토리.
//
//  `OAuthTokens`는 이름은 OAuth지만 실제로는 "provider 호출에 쓰는 Bearer 토큰 +
//  계정 메타데이터"를 담는 일반 자격증명 컨테이너다. refresh/만료가 없는
//  API 키도 그대로 담을 수 있다(만료가 nil이면 `isExpired == false`라
//  `TokenStore.validTokens`가 그대로 반환한다).
//

import Foundation

extension OAuthTokens {
    /// 사용자가 붙여넣은 API 키를 자격증명으로 감싼다(refresh·만료 없음).
    /// 계정 이메일/플랜은 최초 usage 조회 응답에서 채워질 수 있으므로 여기선 선택.
    static func apiKey(_ key: String, email: String? = nil, plan: String? = nil) -> OAuthTokens {
        OAuthTokens(
            accessToken: key.trimmingCharacters(in: .whitespacesAndNewlines),
            refreshToken: nil,
            expiresAt: nil,
            scopes: [],
            accountEmail: email,
            plan: plan
        )
    }
}
