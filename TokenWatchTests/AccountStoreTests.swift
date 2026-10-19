//
//  AccountStoreTests.swift
//  TokenWatchTests
//
//  앱 계정 상태 전이 검증(가짜 인증 + 가짜 Firestore).
//  - 로그인 성공 → 프로필 404면 needsProfile, 200이면 signedIn
//  - 로그인 취소·충돌은 signedOut으로 돌아오고 충돌은 안내를 남긴다
//  - 프로필 생성: 입력 오류·약관 미동의는 서버를 부르지 않는다, 배틀태그가 겹치면 다시 뽑는다
//  - 운영자: 전용 아바타가 번들에 없으면 고른 아바타로 그린다
//  - 데모 중에는 어떤 진입점도 서버를 부르지 않는다
//  - 삭제: 재인증 취소·폐기 실패면 아무것도 지우지 않는다, Auth 삭제만 실패하면 needsProfile
//  - 캐시가 같은 계정이면 즉시 signedIn으로 복원한다
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
    var deleteSucceeds = true
    var operatorClaim = false
    var sessionStatus: AccountSessionStatus = .valid
    private(set) var deleteCalls = 0
    private(set) var signOutCalls = 0
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

    func deleteUser() async -> Bool {
        deleteCalls += 1
        if deleteSucceeds { currentUser = nil; onChange?(nil) }
        return deleteSucceeds
    }

    func signOut() { signOutCalls += 1; currentUser = nil; onChange?(nil) }
    func idToken(forceRefresh: Bool) async -> String? { currentUser == nil ? nil : "token" }
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

    private func makeStore(auth: FakeAccountAuth, server: FakeFirestore, demo: Bool = false,
                           suite: String = #function) -> (AccountStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "AccountStoreTests.\(suite)")!
        defaults.removePersistentDomain(forName: "AccountStoreTests.\(suite)")
        let store = AccountStore(auth: auth, projectID: "demo-proj", transport: { try await server.handle($0) },
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
        let (store, _) = makeStore(auth: auth, server: server)
        await store.signIn(with: .apple)
        let before = server.requests.count
        #expect(await store.createProfile(nickname: "a", avatarID: "cat", termsAccepted: true) == .invalid(.tooShort))
        #expect(await store.createProfile(nickname: "모험가", avatarID: "cat", termsAccepted: false) == .invalid(.termsRequired))
        #expect(server.requests.count == before)
    }

    @Test func createProfileCommitsAndSignsIn() async {
        let auth = FakeAccountAuth()
        auth.signInResult = .success(user, isNew: true)
        let server = FakeFirestore()
        server.responses = [.init(status: 404), .init(status: 404), .init(status: 200)]   // 프로필 GET, 태그 예약 GET, commit
        let (store, _) = makeStore(auth: auth, server: server)
        await store.signIn(with: .apple)
        #expect(await store.createProfile(nickname: " 모험가 ", avatarID: "cat", termsAccepted: true) == .saved)
        #expect(store.profile?.nickname == "모험가")
        #expect(store.profile?.termsAcceptedVersion == PlayerProfile.currentTermsVersion)
        let tag = store.profile?.tag ?? ""
        #expect(NicknamePolicy.isValidTag(tag) && !NicknamePolicy.isRepdigit(tag))
        #expect(server.requests[1].url?.absoluteString.contains("nametags/") == true)
        #expect(server.requests.last?.url?.path.hasSuffix(":commit") == true)
    }

    /// 뽑은 태그가 다른 계정 것이면 새로 뽑아 저장한다(사용자에게는 taken이 보이지 않는다).
    @Test func takenTagIsRerolled() async {
        let auth = FakeAccountAuth()
        auth.signInResult = .success(user, isNew: true)
        let server = FakeFirestore()
        server.responses = [.init(status: 404),                                                   // 프로필 GET
                            .init(status: 200, body: #"{"fields":{"uid":{"stringValue":"other"}}}"#), // 태그 1 — 남의 것
                            .init(status: 404),                                                   // 태그 2 — 비어 있음
                            .init(status: 200)]                                                   // commit
        let (store, _) = makeStore(auth: auth, server: server)
        await store.signIn(with: .apple)
        #expect(await store.createProfile(nickname: "모험가", avatarID: "cat", termsAccepted: true) == .saved)
        #expect(server.requests.count == 4)
    }

    @Test func operatorWithoutArtFallsBackToChosenAvatar() async {
        let auth = FakeAccountAuth()
        auth.signInResult = .success(user, isNew: false)
        auth.operatorClaim = true
        let server = FakeFirestore()
        server.responses = [.init(status: 200, body: Self.profileJSON)]
        let (store, _) = makeStore(auth: auth, server: server)
        await store.signIn(with: .apple)
        #expect(store.isOperator)
        let profile = try! #require(store.profile)
        // 전용 비트맵이 아직 번들에 없으므로 고른 아바타 그대로다.
        #expect(AvatarCatalog.operatorAvatar == nil)
        #expect(store.displayAvatarID(for: profile) == "cat")
        // 운영자 전용 아바타는 선택 격자에 절대 없다.
        #expect(!AvatarCatalog.ids.contains(AvatarCatalog.operatorAvatarID))
    }

    @Test func demoBlocksEveryEntryPoint() async {
        let auth = FakeAccountAuth()
        auth.currentUser = user
        auth.signInResult = .success(user, isNew: false)
        let server = FakeFirestore()
        let (store, _) = makeStore(auth: auth, server: server, demo: true)
        await store.refreshProfile()
        await store.signIn(with: .apple)
        _ = await store.changeAvatar("cat")
        await store.deleteAccount()
        store.signOut()
        // start()가 띄운 새로고침 Task도 데모 게이트에서 멈춘다.
        await Task.yield()
        #expect(server.requests.isEmpty)
        #expect(auth.signOutCalls == 0 && auth.deleteCalls == 0)
    }

    @Test func deletionStopsWhenRevokeFails() async {
        let auth = FakeAccountAuth()
        auth.signInResult = .success(user, isNew: false)
        let server = FakeFirestore()
        server.responses = [.init(status: 200, body: Self.profileJSON)]
        let (store, _) = makeStore(auth: auth, server: server)
        await store.signIn(with: .apple)
        auth.reauthResult = .revokeFailed
        await store.deleteAccount()
        #expect(store.profile != nil)
        #expect(store.notice == .revokeFailed)
        #expect(server.requests.count == 1)   // 삭제 커밋을 보내지 않았다
        #expect(auth.deleteCalls == 0)

        auth.reauthResult = .cancelled
        store.notice = nil
        await store.deleteAccount()
        #expect(store.profile != nil && store.notice == nil && auth.deleteCalls == 0)
    }

    @Test func authDeleteFailureLeavesNeedsProfile() async {
        let auth = FakeAccountAuth()
        auth.signInResult = .success(user, isNew: false)
        auth.deleteSucceeds = false
        let server = FakeFirestore()
        server.responses = [.init(status: 200, body: Self.profileJSON), .init(status: 200)]   // 프로필 GET, 삭제 commit
        let (store, _) = makeStore(auth: auth, server: server)
        await store.signIn(with: .apple)
        await store.deleteAccount()
        #expect(store.state == .needsProfile)
        #expect(store.notice == .deleteFailed)
    }

    @Test func successfulDeletionSignsOut() async {
        let auth = FakeAccountAuth()
        auth.signInResult = .success(user, isNew: false)
        let server = FakeFirestore()
        server.responses = [.init(status: 200, body: Self.profileJSON), .init(status: 200)]
        let (store, defaults) = makeStore(auth: auth, server: server)
        await store.signIn(with: .apple)
        await store.deleteAccount()
        #expect(store.state == .signedOut)
        #expect(PlayerProfileCache.load(from: defaults) == nil)
        #expect(server.requests.last?.httpMethod == "POST")
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

        PlayerProfileCache(uid: "someone-else", nickname: "x", tag: "0001", avatarId: "cat", nicknameChangedAtMs: 1).save(to: defaults)
        let other = AccountStore(auth: auth, projectID: "demo-proj", isDemo: { false }, defaults: defaults)
        #expect(other.state == .loading)
    }
}
