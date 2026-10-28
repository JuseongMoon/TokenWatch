//
//  PlayerProfile.swift
//  TokenWatch
//
//  앱 계정(TokenWatch 자체 계정 — provider 계정과 별개)의 프로필 모델과 닉네임 규칙.
//  서버 문서 `players/{uid}`와 1:1이다. 이메일·provider 정보·토큰은 담지 않는다.
//  닉네임 규칙·에러 코드·금칙어는 Android와 같은 값을 쓴다(서버 규칙 정규식과도 같다).
//
//  배틀태그 방식: 닉네임은 겹쳐도 되고 닉네임+4자리 태그 쌍이 고유하다. 화면에는 항상 `닉네임 #1234`로 붙인다.
//  태그는 서버(`setProfile`)가 뽑는다 — 닉네임을 바꿀 때마다 새로 뽑고, 네 자리가 모두 같은 태그(0000·1111…)는 운영자만 쓴다.
//

import Foundation

/// 앱 계정 로그인 방법. 분석 파라미터 `method` 값이기도 하다.
nonisolated enum AccountMethod: String, Sendable, CaseIterable {
    case apple
    case google

    /// Firebase Auth `providerData[].providerID` 값.
    var firebaseProviderID: String {
        switch self {
        case .apple: return "apple.com"
        case .google: return "google.com"
        }
    }

    init?(firebaseProviderID: String) {
        guard let m = Self.allCases.first(where: { $0.firebaseProviderID == firebaseProviderID }) else { return nil }
        self = m
    }
}

/// `players/{uid}` 문서. 시각은 전부 epoch 밀리초 정수(서버 시차 보정값).
nonisolated struct PlayerProfile: Equatable, Sendable {
    /// 이용약관·개인정보 동의 버전. 약관을 개정하면 올리고 재동의를 받는다.
    /// 2 = 몬스터 사냥·길드 순위 개정. 새 가입은 2로 만들고, 1에 동의한 계정은 몬스터 동의 화면에서 2를 받는다.
    static let currentTermsVersion = 2

    var nickname: String
    var nicknameLower: String
    /// 배틀태그 4자리("0000"~"9999", 앞자리 0 유지). 닉네임과 함께 고유 키가 된다.
    var tag: String
    var nicknameChangedAtMs: Int64
    /// `avatar: {kind: "preset", id}`의 id. 프리셋이 아닌 종류(V2 이후)는 디코딩 때 기본값으로 바꾼다.
    var avatarID: String
    var termsAcceptedVersion: Int
    var createdAtMs: Int64
    var updatedAtMs: Int64

    /// 화면 표시용 `닉네임 #1234`(닉네임과 태그 사이 한 칸).
    var nametag: String { "\(nickname) #\(tag)" }
}

/// 닉네임·프로필 저장 실패 코드(계약 §5). 클라이언트는 이 값으로 문구를 고른다.
nonisolated enum NicknameError: String, Sendable, CaseIterable {
    case tooShort = "too_short"
    case tooLong = "too_long"
    case invalidChars = "invalid_chars"
    case taken
    case bannedWord = "banned_word"
    case cooldown
    case termsRequired = "terms_required"
}

/// 닉네임 정규화·검증·쿨다운. 순서: NFC → 앞뒤 공백 제거 → 길이 → 허용 문자 → 금칙어.
nonisolated enum NicknamePolicy {
    static let minLength = 2
    static let maxLength = 12
    /// 닉네임 변경 간격 — 30일에 1회(생성 시각도 변경 시각으로 친다).
    static let cooldownMs: Int64 = 30 * 24 * 60 * 60 * 1000

    /// NFC 정규화 후 앞뒤 공백을 지운다. macOS에서 붙여 넣은 NFD 한글(자모 분리)을 음절로 합친다.
    static func normalize(_ raw: String) -> String {
        raw.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 정규화된 닉네임 검증. 통과하면 nil.
    /// 길이는 UTF-16 코드 유닛 수로 센다(Android `String.length`와 같은 값 — 허용 문자는 전부 1유닛).
    static func validate(_ normalized: String) -> NicknameError? {
        let length = normalized.utf16.count
        if length < minLength { return .tooShort }
        if length > maxLength { return .tooLong }
        guard normalized.unicodeScalars.allSatisfy(isAllowed) else { return .invalidChars }
        if containsBannedWord(lower(normalized)) { return .bannedWord }
        return nil
    }

    /// 허용 문자: 한글 음절(가–힣), 영문, 숫자, `_`, `-`. 서버 규칙 `^[가-힣A-Za-z0-9_-]{2,12}$`과 같다.
    static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xAC00...0xD7A3, 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x5F, 0x2D: return true
        default: return false
        }
    }

    /// 중복 검사 키. 허용 문자 중 대소문자가 있는 건 ASCII뿐이라 로케일과 무관하다.
    static func lower(_ normalized: String) -> String {
        String(normalized.unicodeScalars.map { scalar in
            (0x41...0x5A).contains(scalar.value) ? Character(Unicode.Scalar(scalar.value + 32)!) : Character(scalar)
        })
    }

    // MARK: 배틀태그

    /// 4자리 숫자 태그인지.
    static func isValidTag(_ tag: String) -> Bool {
        tag.utf8.count == 4 && tag.utf8.allSatisfy { (0x30...0x39).contains($0) }
    }

    static func containsBannedWord(_ lower: String) -> Bool {
        bannedWords.contains { lower.contains($0) }
    }

    /// 다음 변경까지 남은 밀리초. 0이면 지금 바꿀 수 있다(정확히 30일이 지난 순간부터 허용).
    static func cooldownRemainingMs(lastChangedAtMs: Int64, nowMs: Int64) -> Int64 {
        max(0, lastChangedAtMs + cooldownMs - nowMs)
    }

    /// 금칙어(소문자, 부분 일치). 저장 전 사전 검사용이고, 정본은 더 넓은 목록으로 판정하는 서버(`setProfile`)다.
    /// Android와 같은 목록을 쓴다.
    static let bannedWords: [String] = [
        // 운영자 사칭
        "admin", "moderator", "official", "tokenwatch",
        "운영자", "관리자", "운영팀", "공식", "토큰워치",
        // 영어 비속어·혐오
        "fuck", "shit", "bitch", "cunt", "nigger", "nigga", "faggot", "retard", "porn", "hitler", "nazi",
        // 한국어 비속어·혐오
        "씨발", "시발", "씨빨", "좆", "존나", "병신", "븅신", "개새끼", "지랄",
        "느금", "니미", "애미", "애비", "섹스", "보지", "자지", "창녀",
    ]
}

/// 오프라인에서 PLAYER 박스를 그리기 위한 최소 캐시. 정본은 서버다.
/// 비자격 정보(uid·닉네임·아바타 ID)만 담는다 — 토큰·이메일은 넣지 않는다. 키·JSON 필드는 Android와 같다.
nonisolated struct PlayerProfileCache: Codable, Equatable, Sendable {
    static let storageKey = "tokenwatch.player.profile.v1"

    let uid: String
    let nickname: String
    let tag: String
    let avatarId: String
    let nicknameChangedAtMs: Int64
    /// 동의한 약관 버전. 이 필드가 생기기 전 캐시에는 없다(nil).
    var termsAcceptedVersion: Int? = nil

    static func load(from defaults: UserDefaults = .standard) -> PlayerProfileCache? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(PlayerProfileCache.self, from: data)
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}
