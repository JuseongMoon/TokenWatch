//
//  AccountStoreTests.swift
//  TokenWatchTests
//
//  앱 계정 상태 전이 검증(가짜 인증 + 가짜 Firestore).
//  - 로그인 성공 → 프로필 404면 needsProfile, 200이면 signedIn
//  - 로그인 취소·충돌은 signedOut으로 돌아오고 충돌은 안내를 남긴다
//  - 프로필 생성: 입력 오류·약관 미동의는 서버를 부르지 않는다, 예약 중복은 taken
//  - 데모 중에는 어떤 진입점도 서버를 부르지 않는다
//  - 삭제: 재인증 취소·폐기 실패면 아무것도 지우지 않는다, Auth 삭제만 실패하면 needsProfile
//  - 캐시가 같은 계정이면 즉시 signedIn으로 복원한다
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
    private(set) var deleteCalls = 0
    private(set) var signOutCalls = 0
    private var onChange: ((AccountUser?) -> Void)?

    func startListening(_ onChange: @escaping (AccountUser?) -> Void) { self.onChange = onChange }

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
}

@MainActor
struct AccountStoreTests {
    private let user = AccountUser(uid: "u1", methods: [.apple])
    private static let profileJSON = """
    {"fields":{"nickname":{"stringValue":"모험가"},"nicknameLower":{"stringValue":"모험가"},
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
        server.responses = [.init(status: 404), .init(status: 404), .init(status: 200)]   // 프로필 GET, 예약 GET, commit
        let (store, _) = makeStore(auth: auth, server: server)
        await store.signIn(with: .apple)
        #expect(await store.createProfile(nickname: " 모험가 ", avatarID: "cat", termsAccepted: true) == .saved)
        #expect(store.profile?.nickname == "모험가")
        #expect(store.profile?.termsAcceptedVersion == PlayerProfile.currentTermsVersion)
        #expect(server.requests.last?.url?.path.hasSuffix(":commit") == true)
    }

    @Test func takenReservationIsReported() async {
        let auth = FakeAccountAuth()
        auth.signInResult = .success(user, isNew: true)
        let server = FakeFirestore()
        server.responses = [.init(status: 404), .init(status: 200, body: #"{"fields":{"uid":{"stringValue":"other"}}}"#)]
        let (store, _) = makeStore(auth: auth, server: server)
        await store.signIn(with: .apple)
        #expect(await store.createProfile(nickname: "모험가", avatarID: "cat", termsAccepted: true) == .invalid(.taken))
        #expect(store.state == .needsProfile)
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

    @Test func restoresCachedProfileForSameAccount() {
        let auth = FakeAccountAuth()
        auth.currentUser = user
        let defaults = UserDefaults(suiteName: "AccountStoreTests.cache")!
        defaults.removePersistentDomain(forName: "AccountStoreTests.cache")
        PlayerProfileCache(uid: "u1", nickname: "모험가", avatarId: "cat", nicknameChangedAtMs: 1).save(to: defaults)
        let store = AccountStore(auth: auth, projectID: "demo-proj", isDemo: { false }, defaults: defaults)
        #expect(store.profile?.nickname == "모험가")

        PlayerProfileCache(uid: "someone-else", nickname: "x", avatarId: "cat", nicknameChangedAtMs: 1).save(to: defaults)
        let other = AccountStore(auth: auth, projectID: "demo-proj", isDemo: { false }, defaults: defaults)
        #expect(other.state == .loading)
    }
}
