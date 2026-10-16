//
//  NicknamePolicyTests.swift
//  TokenWatchTests
//
//  앱 계정 닉네임 규칙(계약 §5) 검증 — Android NicknamePolicyTest와 같은 경계를 본다.
//  - NFD 한글 → NFC 통과, 앞뒤 공백 제거
//  - 길이 2/12 통과, 1/13 실패(UTF-16 유닛 기준)
//  - 허용 문자 밖(이모지·공백·`.`·자모) → invalid_chars
//  - 소문자 키는 ASCII만 바꾼다, 금칙어는 대소문자 무시
//  - 쿨다운 경계: 7일 −1ms는 남음, 정확히 7일이면 가능
//  - 에러 코드 문자열이 계약과 같다
//

import Testing
import Foundation
@testable import TokenWatch

struct NicknamePolicyTests {
    @Test func nfdHangulIsNormalized() {
        let nfd = "모험가".decomposedStringWithCanonicalMapping
        #expect(nfd.unicodeScalars.count > 3)
        let normalized = NicknamePolicy.normalize(nfd)
        #expect(normalized == "모험가")
        #expect(NicknamePolicy.validate(normalized) == nil)
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(NicknamePolicy.normalize("  slime_01 \n") == "slime_01")
    }

    @Test func lengthBoundaries() {
        #expect(NicknamePolicy.validate("a") == .tooShort)
        #expect(NicknamePolicy.validate("") == .tooShort)
        #expect(NicknamePolicy.validate("ab") == nil)
        #expect(NicknamePolicy.validate(String(repeating: "가", count: 12)) == nil)
        #expect(NicknamePolicy.validate(String(repeating: "가", count: 13)) == .tooLong)
    }

    @Test func rejectsCharactersOutsideTheAllowedSet() {
        #expect(NicknamePolicy.validate("ab cd") == .invalidChars)
        #expect(NicknamePolicy.validate("ab.cd") == .invalidChars)
        #expect(NicknamePolicy.validate("슬라임😀") == .invalidChars)
        #expect(NicknamePolicy.validate("ㄱㄴㄷ") == .invalidChars)   // 자모는 음절이 아니다
        #expect(NicknamePolicy.validate("Slime-Hunter_7") == .tooLong)
        #expect(NicknamePolicy.validate("Slime-Hunt_7") == nil)
    }

    @Test func lowerChangesASCIIOnly() {
        #expect(NicknamePolicy.lower("SlimeKING") == "slimeking")
        #expect(NicknamePolicy.lower("모험가ABC") == "모험가abc")
        #expect(NicknamePolicy.lower("I_i") == "i_i")   // 터키어 점 없는 i 같은 로케일 변환 없음
    }

    @Test func bannedWordsIgnoreCase() {
        #expect(NicknamePolicy.validate("TokenWatch1") == .bannedWord)
        #expect(NicknamePolicy.validate("ADMIN") == .bannedWord)
        #expect(NicknamePolicy.validate("관리자님") == .bannedWord)
        #expect(NicknamePolicy.validate("슬라임사냥꾼") == nil)
        #expect(NicknamePolicy.bannedWords.allSatisfy { $0 == NicknamePolicy.lower($0) })
    }

    @Test func cooldownBoundary() {
        let changed: Int64 = 1_800_000_000_000
        let week = NicknamePolicy.cooldownMs
        #expect(week == 604_800_000)
        #expect(NicknamePolicy.cooldownRemainingMs(lastChangedAtMs: changed, nowMs: changed + week - 1) == 1)
        #expect(NicknamePolicy.cooldownRemainingMs(lastChangedAtMs: changed, nowMs: changed + week) == 0)
        #expect(NicknamePolicy.cooldownRemainingMs(lastChangedAtMs: changed, nowMs: changed) == week)
    }

    @Test func errorCodesMatchContract() {
        #expect(NicknameError.allCases.map(\.rawValue) ==
                ["too_short", "too_long", "invalid_chars", "taken", "banned_word", "cooldown", "terms_required"])
    }

    @Test func profileCacheRoundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "NicknamePolicyTests.cache"))
        defer { defaults.removePersistentDomain(forName: "NicknamePolicyTests.cache") }
        let cache = PlayerProfileCache(uid: "u1", nickname: "모험가", avatarId: "mage", nicknameChangedAtMs: 42)
        cache.save(to: defaults)
        #expect(PlayerProfileCache.load(from: defaults) == cache)
        // 저장 형식은 Android와 같은 JSON 키다.
        let raw = try #require(defaults.data(forKey: PlayerProfileCache.storageKey))
        let keys = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any]).keys.sorted()
        #expect(keys == ["avatarId", "nickname", "nicknameChangedAtMs", "uid"])
        PlayerProfileCache.clear(in: defaults)
        #expect(PlayerProfileCache.load(from: defaults) == nil)
    }
}
