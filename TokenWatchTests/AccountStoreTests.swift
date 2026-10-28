//
//  AccountStoreTests.swift
//  TokenWatchTests
//
//  앱 계정 상태 전이 검증(가짜 인증 + 가짜 Firestore + 가짜 callable).
//  - 로그인 성공 → 프로필 404면 needsProfile, 200이면 signedIn
//  - 로그인 취소·충돌은 signedOut으로 돌아오고 충돌은 안내를 남긴다
//  - 프로필 생성: 입력 오류·약관 미동의는 서버를 부르지 않는다, `setProfile create`에 지금 약관 버전을 싣는다,
//    서버의 닉네임 오류 코드는 입력 오류로 보여 준다, 응답을 잃어도 이미 만들어졌으면 저장된 것으로 본다
//  - 운영자: 고른 아바타와 상관없이 전용 아바타(왕관 슬라임)로 그린다
//  - 데모 중에는 어떤 진입점도 서버를 부르지 않는다
//  - 삭제: 재인증 취소·폐기 실패면 서버를 부르지 않는다, 서버 삭제가 실패하면 계정을 그대로 둔다,
//    성공하면 새 토큰으로 `deleteAccount`를 부르고 로그아웃 상태가 된다
//  - 캐시가 같은 계정이면 즉시 signedIn으로 복원한다(약관 버전이 없는 이전 캐시는 동의 전으로)
//  - 서버에서 계정이 지워졌으면 다시 읽을 때 로그아웃 상태로 정리하고, 확인 실패면 프로필을 유지한다
//

import Testing
import Foundation
@testable import TokenWatch

@MainActor
final class FakeAccountAuth: AccountAuthenticating {
    var isAvailable = true
    var isGoogleAvailable = true
    var currentUser: AccountUser?
    var signInResult: AccountAuthResult = .cancelled
    var reauthResult: AccountReauthResult = .ok
    var operatorClaim = false
    var sessionStatus: AccountSessionStatus = .valid
    private(set) var signOutCalls = 0
    private(set) var forcedTokenRefreshes = 0
    private var onChange: ((AccountUser?) -> Void)?

    func startListening(_ onChange: @escaping (AccountUser?) -> Void) { self.onChange = onChange }
    func reloadUser() async -> AccountSessionStatus { currentUser == nil ? .revoked : sessionStatus }

    func signIn(with method: AccountMethod) async -> AccountAuthResult {
        if case .success(let user, _) = signInResult {
            currentUser = user
            onChange?(user)   // 실제 SDK처럼 리스너가 결과보다 먼저 불릴 수 있다
        }
        return signInResult
    }

    func link(_ method: AccountMethod) async -> AccountAuthResult { .alreadyInUse }
    func reauthenticateForDeletion() async -> AccountReauthResult { reauthResult }

    func signOut() { signOutCalls += 1; currentUser = nil; onChange?(nil) }

    func idToken(forceRefresh: Bool) async -> String? {
        if forceRefresh { forcedTokenRefreshes += 1 }
        return currentUser == nil ? nil : "token"
    }
    func isOperator(forceRefresh: Bool) async -> Bool { currentUser != nil && operatorClaim }
}

@MainActor
struct AccountStoreTests {
    private let user = AccountUser(uid: "u1", methods: [.apple])
    private static let profileJSON = """
    {"fields":{"nickname":{"stringValue":"모험가"},"nicknameLower":{"stringValue":"모험가"},"tag":{"stringValue":"0042"},
      "nicknameChangedAtMs":{"integerValue":"1"},"createdAtMs":{"integerValue":"1"},
      "avatar":{"mapValue":{"fields":{"kind":{"stringValue":"preset"},"id":{"stringValue":"cat"}}}}}}
    """

    /// `setProfile` 응답 본문(서버 공개 프로필).
    private static func profileResult(nickname: String = "모험가", tag: String = "8571", terms: Int = 2) -> String {
        #"{"result":{"profile":{"nickname":"\#(nickname)","nicknameLower":"\#(nickname.lowercased())","tag":"\#(tag)","#
            + #""nicknameChangedAtMs":5,"avatar":{"kind":"preset","id":"cat"},"termsAcceptedVersion":\#(terms),"#
            + #""createdAtMs":5,"updatedAtMs":5}}}"#
    }

    private func makeStore(auth: FakeAccountAuth, server: FakeFirestore, functions: FakeFunctions? = nil,
                           demo: Bool = false, suite: String = #function) -> (AccountStore, UserDefaults) {
        let functions = functions ?? FakeFunctions()
        let defaults = UserDefaults(suiteName: "AccountStoreTests.\(suite)")!
        defaults.removePersistentDomain(forName: "AccountStoreTests.\(suite)")
        let store = AccountStore(auth: auth, projectID: "demo-proj", transport: { try await server.handle($0) },
                                 callTransport: { try await functions.handle($0) },
                                 isDemo: { demo }, defaults: defaults)
        store.start()
        return (store, defaults)
    }

    @Test func unavailableWithoutFirebase() {
        let auth = FakeAccountAuth()
        auth.isAvailable = false
        let store = AccountStore(auth: auth, projectID: "demo-proj")
        #expect(store.state == .unavailable)
        #expect(!store.isAvailable)
    }

    @Test func firstSignInNeedsProfile() async {
        let auth = FakeAccountAuth()
        auth.signInResult = .success(user, isNew: true)
        let server = FakeFirestore()
        server.responses = [.init(status: 404)]
        let (store, _) = makeStore(auth: auth, server: server)
        await store.signIn(with: .apple)
        #expect(store.state == .needsProfile)
        #expect(store.methods == [.apple])
        #expect(server.requests.count == 1)   // 리스너와 로그인 흐름이 겹쳐 읽지 않는다
    }

    @Test func returningSignInLoadsProfile() async {
        let auth = FakeAccountAuth()
        auth.signInResult = .success(user, isNew: false)
        let server = FakeFirestore()
        server.responses = [.init(status: 200, body: Self.profileJSON)]
        let (store, defaults) = makeStore(auth: auth, server: server)
        await store.signIn(with: .apple)
        #expect(store.profile?.nickname == "모험가")
        #expect(PlayerProfileCache.load(from: defaults)?.avatarId == "cat")
    }

    @Test func cancelAndConflictReturnToSignedOut() async {
        let auth = FakeAccountAuth()
        let server = FakeFirestore()
        let (store, _) = makeStore(auth: auth, server: server)
        auth.signInResult = .cancelled
        await store.signIn(with: .google)
        #expect(store.state == .signedOut && store.notice == nil)
        auth.signInResult = .existsWithDifferentMethod
        await store.signIn(with: .google)
        #expect(store.state == .signedOut && store.notice == .existsWithDifferentMethod)
        #expect(server.requests.isEmpty)
    }

    @Test func invalidInputNeverHitsServer() async {
        let auth = FakeAccountAuth()
        auth.signInResult = .success(user, isNew: true)
        let server = FakeFirestore()
        server.responses = [.init(status: 404)]
        let functions = FakeFunctions()
        let (store, _) = makeStore(auth: auth, server: server, functions: functions)
        await store.signIn(with: .apple)
        let before = server.requests.count
        #expect(await store.createProfile(nickname: "a", avatarID: "cat", termsAccepted: true) == .invalid(.tooShort))
        #expect(await store.createProfile(nickname: "모험가", avatarID: "cat", termsAccepted: false) == .invalid(.termsRequired))
        #expect(server.requests.count == before)
        #expect(functions.calls.isEmpty)
    }

    @Test func createProfileCallsServerAndSignsIn() async {
        let auth = FakeAccountAuth()
        auth.signInResult = .success(user, isNew: true)
        let server = FakeFirestore()
        server.responses = [.init(status: 404)]
        let functions = FakeFunctions()
        functions.responses["setProfile"] = [(200, Self.profileResult())]
        let (store, defaults) = makeStore(auth: auth, server: server, functions: functions)
        await store.signIn(with: .apple)
        #expect(await store.createProfile(nickname: " 모험가 ", avatarID: "cat", termsAccepted: true) == .saved)
        let sent = try! #require(functions.calls.first?.data)
        #expect(sent["op"] as? String == "create")
        #expect(sent["nickname"] as? String == "모험가")   // 정규화한 값을 보낸다
        #expect(sent["avatarId"] as? String == "cat")
        #expect(sent["termsAcceptedVersion"] as? Int == PlayerProfile.currentTermsVersion)
        #expect(sent["tag"] == nil)   // 태그는 서버가 뽑는다
        #expect(store.profile?.tag == "8571")
        #expect(store.profile?.termsAcceptedVersion == 2)
        #expect(PlayerProfileCache.load(from: defaults)?.termsAcceptedVersion == 2)
        #expect(server.requests.count == 1)   // Firestore에는 쓰지 않는다
    }

    /// 서버 금칙어·태그 소진 같은 닉네임 오류는 입력 오류로 보여 주고, 저장 실패 안내는 띄우지 않는다.
    @Test func serverNicknameErrorIsShownAsInputError() async {
        let auth = FakeAccountAuth()
        auth.signInResult = .success(user, isNew: true)
        let server = FakeFirestore()
        server.responses = [.init(status: 404)]
        let functions = FakeFunctions()
        functions.responses["setProfile"] = [(400, #"{"error":{"status":"INVALID_ARGUMENT","details":{"code":"banned_word"}}}"#)]
        let (store, _) = makeStore(auth: auth, server: server, functions: functions)
        await store.signIn(with: .apple)
        #expect(await store.createProfile(nickname: "모험가", avatarID: "cat", termsAccepted: true) == .invalid(.bannedWord))
        #expect(store.notice == nil)
        #expect(store.state == .needsProfile)
    }

    /// 응답만 잃었고 서버에는 이미 만들어졌으면 다시 읽어 저장된 것으로 본다.
    @Test func lostCreateResponseRecoversByReading() async {
        let auth = FakeAccountAuth()
        auth.signInResult = .success(user, isNew: true)
        let server = FakeFirestore()
        server.responses = [.init(status: 404), .init(status: 200, body: Self.profileJSON)]
        let functions = FakeFunctions()
        functions.failTransport = true
        let (store, _) = makeStore(auth: auth, server: server, functions: functions)
        await store.signIn(with: .apple)
        #expect(await store.createProfile(nickname: "모험가", avatarID: "cat", termsAccepted: true) == .saved)
        #expect(store.profile?.tag == "0042")
        #expect(store.notice == nil)
    }

    @Test func changeAvatarUsesServerProfile() async {
        let auth = FakeAccountAuth()
        auth.signInResult = .success(user, isNew: false)
        let server = FakeFirestore()
        server.responses = [.init(status: 200, body: Self.profileJSON)]
        let functions = FakeFunctions()
        functions.responses["setProfile"] = [(200, Self.profileResult(tag: "0042"))]
        let (store, _) = makeStore(auth: auth, server: server, functions: functions)
        await store.signIn(with: .apple)
        #expect(await store.changeAvatar("mage") == .saved)
        #expect(functions.calls.first?.data["op"] as? String == "avatar")
        #expect(functions.calls.first?.data["avatarId"] as? String == "mage")
        #expect(store.profile?.updatedAtMs == 5)
    }

    @Test func operatorDrawsWithOperatorAvatar() async {
        let auth = FakeAccountAuth()
        auth.signInResult = .success(user, isNew: false)
        auth.operatorClaim = true
        let server = FakeFirestore()
        server.responses = [.init(status: 200, body: Self.profileJSON)]
        let (store, _) = makeStore(auth: auth, server: server)
        await store.signIn(with: .apple)
        #expect(store.isOperator)
        let profile = try! #require(store.profile)
        // 고른 아바타(cat)와 상관없이 운영자 전용 아바타로 그린다. 저장된 값은 그대로다.
        #expect(store.displayAvatarID(for: profile) == AvatarCatalog.operatorAvatarID)
        #expect(profile.avatarID == "cat")
        // 운영자 전용 아바타는 선택 격자에 절대 없다.
        #expect(!AvatarCatalog.ids.contains(AvatarCatalog.operatorAvatarID))
    }

    @Test func demoBlocksEveryEntryPoint() async {
        let auth = FakeAccountAuth()
        auth.currentUser = user
        auth.signInResult = .success(user, isNew: false)
        let server = FakeFirestore()
        let functions = FakeFunctions()
        let (store, _) = makeStore(auth: auth, server: server, functions: functions, demo: true)
        await store.refreshProfile()
        await store.signIn(with: .apple)
        _ = await store.changeAvatar("cat")
        await store.deleteAccount()
        store.signOut()
        // start()가 띄운 새로고침 Task도 데모 게이트에서 멈춘다.
        await Task.yield()
        #expect(server.requests.isEmpty)
        #expect(functions.calls.isEmpty)
        #expect(auth.signOutCalls == 0)
    }

    @Test func deletionStopsWhenRevokeFails() async {
        let auth = FakeAccountAuth()
        auth.signInResult = .success(user, isNew: false)
        let server = FakeFirestore()
        server.responses = [.init(status: 200, body: Self.profileJSON)]
        let functions = FakeFunctions()
        let (store, _) = makeStore(auth: auth, server: server, functions: functions)
        await store.signIn(with: .apple)
        auth.reauthResult = .revokeFailed
        await store.deleteAccount()
        #expect(store.profile != nil)
        #expect(store.notice == .revokeFailed)
        #expect(functions.count("deleteAccount") == 0)

        auth.reauthResult = .cancelled
        store.notice = nil
        await store.deleteAccount()
        #expect(store.profile != nil && store.notice == nil && functions.count("deleteAccount") == 0)
        #expect(auth.signOutCalls == 0)
    }

    /// 서버가 거절하면(예: 최근 로그인 아님) 계정을 그대로 두고 실패를 알린다.
    @Test func serverDeleteFailureKeepsAccount() async {
        let auth = FakeAccountAuth()
        auth.signInResult = .success(user, isNew: false)
        let server = FakeFirestore()
        server.responses = [.init(status: 200, body: Self.profileJSON)]
        let functions = FakeFunctions()
        functions.responses["deleteAccount"] = [(400, #"{"error":{"status":"FAILED_PRECONDITION","details":{"code":"requires_recent_login"}}}"#)]
        let (store, _) = makeStore(auth: auth, server: server, functions: functions)
        await store.signIn(with: .apple)
        await store.deleteAccount()
        #expect(store.profile?.nickname == "모험가")
        #expect(store.notice == .deleteFailed)
        #expect(auth.signOutCalls == 0)
    }

    @Test func successfulDeletionSignsOut() async {
        let auth = FakeAccountAuth()
        auth.signInResult = .success(user, isNew: false)
        let server = FakeFirestore()
        server.responses = [.init(status: 200, body: Self.profileJSON)]
        let functions = FakeFunctions()
        functions.responses["deleteAccount"] = [(200, #"{"result":{"deleted":true}}"#)]
        let (store, defaults) = makeStore(auth: auth, server: server, functions: functions)
        var deletedUID: String?
        store.onAccountDeleted = { deletedUID = $0 }
        await store.signIn(with: .apple)
        let refreshesBefore = auth.forcedTokenRefreshes
        await store.deleteAccount()
        #expect(auth.forcedTokenRefreshes > refreshesBefore)   // 재인증 시각이 실린 새 토큰
        #expect(functions.count("deleteAccount") == 1)
        #expect(functions.calls.last?.data.isEmpty == true)
        #expect(store.state == .signedOut)
        #expect(auth.signOutCalls == 1)
        #expect(deletedUID == "u1")
        #expect(PlayerProfileCache.load(from: defaults) == nil)
    }

    /// 응답을 잃었어도 로그인 기록이 이미 없으면 삭제가 끝난 것으로 본다.
    @Test func lostDeleteResponseCountsWhenUserIsGone() async {
        let auth = FakeAccountAuth()
        auth.signInResult = .success(user, isNew: false)
        let server = FakeFirestore()
        server.responses = [.init(status: 200, body: Self.profileJSON)]
        let functions = FakeFunctions()
        functions.failTransport = true
        let (store, _) = makeStore(auth: auth, server: server, functions: functions)
        await store.signIn(with: .apple)
        auth.sessionStatus = .revoked
        await store.deleteAccount()
        #expect(store.state == .signedOut)
        #expect(store.notice == nil)
    }

    /// 웹·다른 기기에서 계정을 지웠으면 캐시를 지우고 로그아웃 상태가 된다(Firestore는 부르지 않는다).
    @Test func revokedSessionSignsOutOnRefresh() async {
        let auth = FakeAccountAuth()
        auth.signInResult = .success(user, isNew: false)
        let server = FakeFirestore()
        server.responses = [.init(status: 200, body: Self.profileJSON)]
        let (store, defaults) = makeStore(auth: auth, server: server)
        await store.signIn(with: .apple)
        #expect(store.profile != nil)
        auth.sessionStatus = .revoked
        await store.refreshProfile()
        #expect(store.state == .signedOut)
        #expect(PlayerProfileCache.load(from: defaults) == nil)
        #expect(auth.signOutCalls == 1)
        #expect(server.requests.count == 1)
    }

    /// 오프라인 등으로 확인하지 못하면 보이던 프로필을 그대로 둔다.
    @Test func unknownSessionKeepsVisibleProfile() async {
        let auth = FakeAccountAuth()
        auth.signInResult = .success(user, isNew: false)
        let server = FakeFirestore()
        server.responses = [.init(status: 200, body: Self.profileJSON)]   // 두 번째 GET은 500
        let (store, _) = makeStore(auth: auth, server: server)
        await store.signIn(with: .apple)
        auth.sessionStatus = .unknown
        await store.refreshProfile()
        #expect(store.profile?.nickname == "모험가")
        #expect(auth.signOutCalls == 0)
    }

    /// 방금 읽었으면 PLAYER 박스가 다시 보여도 서버를 또 부르지 않는다.
    @Test func revalidateSkipsRightAfterRefresh() async {
        let auth = FakeAccountAuth()
        auth.signInResult = .success(user, isNew: false)
        let server = FakeFirestore()
        server.responses = [.init(status: 200, body: Self.profileJSON)]
        let (store, _) = makeStore(auth: auth, server: server)
        await store.signIn(with: .apple)
        auth.sessionStatus = .revoked
        await store.revalidate()
        #expect(store.profile != nil)
        #expect(server.requests.count == 1)
    }

    @Test func restoresCachedProfileForSameAccount() {
        let auth = FakeAccountAuth()
        auth.currentUser = user
        let defaults = UserDefaults(suiteName: "AccountStoreTests.cache")!
        defaults.removePersistentDomain(forName: "AccountStoreTests.cache")
        PlayerProfileCache(uid: "u1", nickname: "모험가", tag: "0042", avatarId: "cat", nicknameChangedAtMs: 1).save(to: defaults)
        let store = AccountStore(auth: auth, projectID: "demo-proj", isDemo: { false }, defaults: defaults)
        #expect(store.profile?.nickname == "모험가")
        #expect(store.profile?.termsAcceptedVersion == 1)   // 약관 버전이 없는 이전 캐시 — 동의 전으로 본다

        PlayerProfileCache(uid: "u1", nickname: "모험가", tag: "0042", avatarId: "cat", nicknameChangedAtMs: 1,
                           termsAcceptedVersion: 2).save(to: defaults)
        let consented = AccountStore(auth: auth, projectID: "demo-proj", isDemo: { false }, defaults: defaults)
        #expect(consented.profile?.termsAcceptedVersion == 2)

        PlayerProfileCache(uid: "someone-else", nickname: "x", tag: "0001", avatarId: "cat", nicknameChangedAtMs: 1).save(to: defaults)
        let other = AccountStore(auth: auth, projectID: "demo-proj", isDemo: { false }, defaults: defaults)
        #expect(other.state == .loading)
    }
}
