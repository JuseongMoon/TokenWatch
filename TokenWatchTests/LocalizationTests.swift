//
//  LocalizationTests.swift
//  TokenWatchTests
//
//  언어 전환(한국어/영어) 데이터 흐름 검증: AppLanguage 해석, L10n 카탈로그,
//  currentLang() UserDefaults 연동, UsageWindow 리셋 요약 로컬라이징.
//

import Testing
import Foundation
@testable import TokenWatch

struct LocalizationTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// AppLanguage → 실제 표시 언어 해석.
    @Test func appLanguageResolves() {
        #expect(AppLanguage.korean.resolved == .ko)
        #expect(AppLanguage.english.resolved == .en)
    }

    /// 카탈로그가 언어별로 서로 다른 문자열을 돌려준다(대표 문자열).
    @Test func catalogDiffersByLanguage() {
        let ko = L10n(lang: .ko)
        let en = L10n(lang: .en)

        #expect(ko.logout == "로그아웃")
        #expect(en.logout == "Log out")
        #expect(ko.settingsLanguageHelp != en.settingsLanguageHelp)
        #expect(ko.paceAhead(12) == "↑ 시간 대비 12%p 빠름")
        #expect(en.paceAhead(12) == "↑ 12%p ahead of pace")
        #expect(ko.errHTTP(429) == "사용량 조회 실패 (HTTP 429).")
        #expect(en.errHTTP(429) == "Failed to fetch usage (HTTP 429).")
        #expect(ko.a11yUsed(42) == "42% 사용")
        #expect(en.a11yUsed(42) == "42% used")
    }

    /// 소진 예상 시각 문구(경계 포함: 0/0/0 → 최소 1분).
    @Test func depletionETALocalized() {
        let ko = L10n(lang: .ko)
        let en = L10n(lang: .en)
        #expect(ko.depletionETA(days: 1, hours: 2, minutes: 3) == "약 1일 2시간 후")
        #expect(en.depletionETA(days: 1, hours: 2, minutes: 3) == "in ~1d 2h")
        #expect(ko.depletionETA(days: 0, hours: 0, minutes: 0) == "약 1분 후")
        #expect(en.depletionETA(days: 0, hours: 0, minutes: 0) == "in ~1m")
    }

    /// UsageWindow 리셋 요약이 언어에 따라 다른 형태로 렌더된다(실제 데이터 흐름).
    @Test func resetSummaryLocalized() {
        let w = UsageWindow(label: "s", usedPercent: 20,
                            resetsAt: now.addingTimeInterval(2 * 3600),
                            kind: .session, windowSeconds: 5 * 3600)
        let ko = w.resetSummary(L10n(lang: .ko), at: now)
        let en = w.resetSummary(L10n(lang: .en), at: now)
        #expect(ko.hasPrefix("리셋"))
        #expect(ko.contains("남음"))
        #expect(en.hasPrefix("resets"))
        #expect(en.contains("left"))

        // 이미 지난 창은 "리셋됨"/"reset".
        let past = UsageWindow(label: "s", usedPercent: 20,
                               resetsAt: now.addingTimeInterval(-100),
                               kind: .session, windowSeconds: 5 * 3600)
        #expect(past.resetSummary(L10n(lang: .ko), at: now) == "리셋됨")
        #expect(past.resetSummary(L10n(lang: .en), at: now) == "reset")
    }

    /// currentLang()가 저장된 설정값을 스레드 안전하게 반영한다(뷰 밖 사용 경로).
    @Test func currentLangReadsUserDefaults() {
        let key = appLanguageStorageKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(AppLanguage.korean.rawValue, forKey: key)
        #expect(currentLang() == .ko)
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: key)
        #expect(currentLang() == .en)
    }
}
