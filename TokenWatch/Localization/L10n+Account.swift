//
//  L10n+Account.swift
//  TokenWatch
//
//  앱 계정(PLAYER) 문구. 터미널 크롬(`PLAYER`, `[ sign in ]`, `[ manage ]` 등)은 번역하지 않고
//  자연어 문장만 둔다. Android는 이 원문을 그대로 옮겨 쓴다(양 플랫폼 같은 문구).
//

import Foundation

extension L10n {
    // MARK: PLAYER 박스
    var playerSignedOutHelp: String {
        lang == .ko ? "TokenWatch 계정으로 로그인하면 닉네임과 아바타를 기기·플랫폼과 상관없이 이어서 써요. 사용량 기능은 로그인 없이도 그대로 쓸 수 있어요."
                    : "Sign in to a TokenWatch account to keep your nickname and avatar across devices and platforms. Usage tracking works without signing in."
    }
    var playerDemoDisabled: String {
        lang == .ko ? "데모 중에는 TokenWatch 계정을 쓸 수 없어요."
                    : "TokenWatch accounts aren't available in demo mode."
    }
    var playerSigningIn: String { lang == .ko ? "로그인 중…" : "signing in…" }
    var playerLoading: String { lang == .ko ? "프로필을 불러오는 중…" : "loading profile…" }
    var playerNeedsProfile: String {
        lang == .ko ? "닉네임과 아바타를 정하면 가입이 끝나요."
                    : "Choose a nickname and avatar to finish signing up."
    }
    var playerLoadFailed: String {
        lang == .ko ? "프로필을 불러오지 못했어요. 네트워크를 확인하고 다시 시도해 주세요."
                    : "Couldn't load your profile. Check your connection and try again."
    }
    var playerDeleting: String { lang == .ko ? "계정을 삭제하는 중…" : "deleting account…" }

    // MARK: 로그인 화면
    var accountLoginIntro: String {
        lang == .ko ? "TokenWatch 계정은 선택 사항이에요. 로그인해도 AI 서비스 계정 정보는 서버로 보내지 않아요."
                    : "A TokenWatch account is optional. Signing in never sends your AI service accounts to our server."
    }
    var accountGoogleNotConfigured: String {
        lang == .ko ? "Google 로그인이 아직 설정되지 않았어요(개발 빌드 안내)."
                    : "Google sign-in isn't configured yet (development build notice)."
    }

    // MARK: 안내(충돌·실패)
    func accountNotice(_ notice: AccountStore.Notice) -> String {
        switch notice {
        case .loginFailed:
            return lang == .ko ? "로그인하지 못했어요. 잠시 뒤 다시 시도해 주세요."
                               : "Couldn't sign in. Please try again in a moment."
        case .googleUnavailable:
            return lang == .ko ? "지금은 Google 로그인을 쓸 수 없어요. Apple로 로그인해 주세요."
                               : "Google sign-in isn't available right now. Please sign in with Apple."
        case .existsWithDifferentMethod:
            return lang == .ko ? "이 이메일은 다른 방법으로 가입돼 있어요. 그 방법으로 로그인한 뒤 연결하세요."
                               : "This email is already registered with another sign-in method. Sign in that way, then link this one."
        case .alreadyInUse:
            return lang == .ko ? "이 로그인은 다른 TokenWatch 계정에 묶여 있어요. 그 계정을 삭제한 뒤 연결할 수 있어요."
                               : "This sign-in is tied to another TokenWatch account. Delete that account to link it here."
        case .linkFailed:
            return lang == .ko ? "연결하지 못했어요. 잠시 뒤 다시 시도해 주세요."
                               : "Couldn't link. Please try again in a moment."
        case .linked(let method):
            return lang == .ko ? "\(accountMethodName(method)) 로그인을 연결했어요."
                               : "Linked \(accountMethodName(method)) sign-in."
        case .saveFailed:
            return lang == .ko ? "저장하지 못했어요. 네트워크를 확인하고 다시 시도해 주세요."
                               : "Couldn't save. Check your connection and try again."
        case .deleteFailed:
            return lang == .ko ? "계정을 삭제하지 못했어요. 다시 시도해 주세요."
                               : "Couldn't delete your account. Please try again."
        case .revokeFailed:
            return lang == .ko ? "Apple 로그인 연결을 해제하지 못해 삭제를 멈췄어요. 다시 시도해 주세요."
                               : "Couldn't disconnect Sign in with Apple, so deletion was stopped. Please try again."
        }
    }

    /// 로그인 방법 이름(고유명사 — 두 언어 같음).
    func accountMethodName(_ method: AccountMethod) -> String {
        switch method {
        case .apple: return "Apple"
        case .google: return "Google"
        }
    }

    // MARK: 닉네임 오류(계약 §5 코드)
    func nicknameError(_ error: NicknameError) -> String {
        switch error {
        case .tooShort:
            return lang == .ko ? "닉네임은 2자 이상이어야 해요." : "Nickname must be at least 2 characters."
        case .tooLong:
            return lang == .ko ? "닉네임은 12자까지 쓸 수 있어요." : "Nickname can be up to 12 characters."
        case .invalidChars:
            return lang == .ko ? "한글·영문·숫자·_·-만 쓸 수 있어요." : "Use only Korean, English letters, numbers, _ and -."
        case .taken:
            return lang == .ko ? "이 닉네임은 쓸 수 있는 #번호가 남지 않았어요. 다른 닉네임을 써 주세요."
                               : "No #numbers are left for this nickname. Please try another one."
        case .bannedWord:
            return lang == .ko ? "쓸 수 없는 단어가 들어 있어요." : "That nickname contains a word that isn't allowed."
        case .cooldown:
            return lang == .ko ? "닉네임은 30일에 한 번 바꿀 수 있어요." : "You can change your nickname once every 30 days."
        case .termsRequired:
            return lang == .ko ? "이용약관과 개인정보 처리방침에 동의해 주세요." : "Please agree to the Terms and Privacy Policy."
        }
    }

    /// 다음 닉네임 변경까지 남은 시간.
    func nicknameCooldownRemaining(days: Int, hours: Int) -> String {
        if lang == .ko {
            return days > 0 ? "다음 변경까지 \(days)일 \(hours)시간" : "다음 변경까지 \(max(hours, 1))시간"
        }
        return days > 0 ? "next change in \(days)d \(hours)h" : "next change in \(max(hours, 1))h"
    }

    // MARK: 프로필 설정 화면
    var profileSetupIntro: String {
        lang == .ko ? "다른 사용자에게 보일 닉네임과 아바타를 골라 주세요. 닉네임 뒤에는 구분용 #번호(예: #8571)가 붙어요. 아바타는 언제든, 닉네임은 30일에 한 번 바꿀 수 있어요."
                    : "Pick the nickname and avatar others will see. A #number (like #8571) is added after your nickname to tell people apart. You can change your avatar anytime and your nickname once every 30 days."
    }
    var nicknamePlaceholder: String { lang == .ko ? "2–12자" : "2–12 chars" }
    var nicknameRule: String {
        lang == .ko ? "한글·영문·숫자·_·- / 2–12자" : "Korean, English, numbers, _ - / 2–12 chars"
    }
    var nicknameTagHint: String {
        lang == .ko ? "닉네임을 바꾸면 #번호도 새로 정해져요. 30일에 한 번 바꿀 수 있어요."
                    : "Changing your nickname also gives you a new #number. You can change it once every 30 days."
    }
    var operatorAvatarNote: String {
        lang == .ko ? "운영자 계정은 고른 아바타와 상관없이 전용 아바타로 보여요."
                    : "Operator accounts always appear with the operator avatar, whatever you pick here."
    }
    var termsAgree: String {
        lang == .ko ? "이용약관과 개인정보 처리방침에 동의합니다" : "I agree to the Terms of Service and Privacy Policy"
    }
    /// 새 가입은 몬스터 사냥 약관(v2)까지 한 번에 동의한다 — 서버로 가는 것과 공개되는 것을 체크 아래에 밝힌다.
    var termsMonsterNote: String {
        lang == .ko ? "몬스터 사냥을 위해 AI 서비스 종류·사용량 창 이름·리셋 시각과 처치 기록을 서버로 보내요. 사용률 수치와 AI 서비스 계정 정보는 보내지 않아요. 닉네임 #번호, 아바타, 점수와 처치 수는 길드 순위에 공개돼요."
                    : "For the monster hunt, the app sends the AI service type, usage window name, reset time, and defeat records to the server. Usage percentages and AI service account details are never sent. Your nickname #number, avatar, score, and defeat counts appear in the guild ranks."
    }
    var termsLink: String { lang == .ko ? "이용약관 ↗" : "terms ↗" }
    var privacyLink: String { lang == .ko ? "개인정보 처리방침 ↗" : "privacy ↗" }
    var profileSetupQuit: String {
        lang == .ko ? "가입을 그만두려면 로그아웃하거나 로그인 기록까지 삭제할 수 있어요."
                    : "To stop signing up, sign out or delete the sign-in record."
    }

    // MARK: 계정 화면
    var accountAvatarHelp: String {
        lang == .ko ? "아바타를 고른 뒤 저장하세요." : "Pick an avatar, then save."
    }
    var accountLinkHelp: String {
        lang == .ko ? "다른 로그인 방법을 연결하면 어느 쪽으로 로그인해도 같은 계정이 열려요."
                    : "Link another sign-in method to open the same account either way."
    }
    var accountSignOutTitle: String {
        lang == .ko ? "TokenWatch 계정에서 로그아웃할까요?" : "Sign out of your TokenWatch account?"
    }
    var accountSignOutMessage: String {
        lang == .ko ? "이 기기에서만 로그아웃돼요. 프로필은 서버에 그대로 남아요."
                    : "You'll be signed out on this device only. Your profile stays on the server."
    }
    var accountDeleteTitle: String {
        lang == .ko ? "TokenWatch 계정을 삭제할까요?" : "Delete your TokenWatch account?"
    }
    var accountDeleteMessage: String {
        lang == .ko ? "닉네임·아바타·몬스터 기록과 길드 순위·로그인 연결이 서버에서 지워지고 되돌릴 수 없어요. 확인을 위해 한 번 더 로그인해요. 위 ACCOUNTS의 AI 서비스 계정은 영향을 받지 않아요."
                    : "Your nickname, avatar, monster records, guild rank, and sign-in links will be erased from the server. This can't be undone. You'll sign in once more to confirm. Your AI service accounts under ACCOUNTS are not affected."
    }
    var accountSignOut: String { lang == .ko ? "로그아웃" : "Sign out" }
    var accountDelete: String { lang == .ko ? "삭제" : "Delete" }
}
