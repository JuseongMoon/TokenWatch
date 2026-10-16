//
//  AccountEventsTests.swift
//  TokenWatchTests
//
//  앱 계정 분석 이벤트(계약 §7) 검증 — 이름·파라미터 키가 계약과 같고, 값은 열거 문자열·정수뿐이며,
//  데모 차단 대상(provider 차원)이 아니고, provider 로그인 실패(loginFail → 진단 보고)와 섞이지 않는다.
//

import Testing
import Foundation
@testable import TokenWatch

@MainActor
struct AccountEventsTests {
    private let events: [(AnalyticsEvent, String, [String: String])] = [
        (.accountLogin(method: .apple, isNew: true), "account_login", ["method": "apple", "is_new": "1"]),
        (.accountLogin(method: .google, isNew: false), "account_login", ["method": "google", "is_new": "0"]),
        (.accountLoginFail(method: .google, stage: .conflict), "account_login_fail", ["method": "google", "stage": "conflict"]),
        (.accountLink(method: .apple), "account_link", ["method": "apple"]),
        (.accountLogout, "account_logout", [:]),
        (.accountDelete, "account_delete", ["surface": "app"]),
        (.profileUpdate(field: .nickname), "profile_update", ["field": "nickname"]),
        (.profileUpdate(field: .avatar), "profile_update", ["field": "avatar"]),
    ]

    @Test func namesAndParametersMatchContract() {
        for (event, name, params) in events {
            #expect(event.name == name)
            #expect(event.parameters.mapValues { "\($0)" } == params)
            #expect(!event.isProviderScoped)
        }
    }

    @Test func isNewIsAnInteger() {
        #expect(AnalyticsEvent.accountLogin(method: .apple, isNew: true).parameters["is_new"] as? Int == 1)
    }

    @Test func accountFailureIsNotProviderLoginFailure() {
        for (event, _, _) in events {
            if case .loginFail = event { Issue.record("앱 계정 이벤트가 loginFail로 나가면 진단 보고로 샌다") }
        }
    }

    @Test func screensHaveClassNames() {
        #expect(ScreenName.accountLogin.rawValue == "account_login")
        #expect(ScreenName.profileSetup.rawValue == "profile_setup")
        #expect(ScreenName.account.rawValue == "account")
        for screen in [ScreenName.accountLogin, .profileSetup, .account] {
            #expect(!screen.screenClass.isEmpty && screen.screenClass.count < 100)
        }
    }

    @Test func failStagesMatchContract() {
        #expect([AccountFailStage.cancel, .provider, .firebase, .conflict].map(\.rawValue) ==
                ["cancel", "provider", "firebase", "conflict"])
        #expect(AccountMethod.allCases.map(\.rawValue) == ["apple", "google"])
    }
}
