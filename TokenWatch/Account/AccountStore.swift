//
//  AccountStore.swift
//  TokenWatch
//
//  앱 계정(TokenWatch 자체 계정) 상태 머신. 로그인·프로필 저장·연결·로그아웃·삭제를 조율한다.
//  provider 계정(AgentStore)과 완전히 별개다 — provider 자격증명·이메일·계정 라벨은 이 경로로 가지 않는다.
//
//  - 데모 모드에서는 모든 진입점이 즉시 반환한다(서버 호출 0건). 데모 진입은 로그아웃이 아니다.
//  - 프로필 정본은 서버다. 오프라인에서 PLAYER 박스를 그리려고 최소 캐시만 UserDefaults에 둔다.
//    PLAYER 박스가 보일 때 서버에서 다시 확인해, 웹·다른 기기에서 지운 계정이면 로그아웃 상태로 정리한다.
//  - 계정 삭제는 재인증 → (Apple) 토큰 폐기 → 프로필 삭제 커밋 → Auth 사용자 삭제 순서이고,
//    재인증 취소나 폐기 실패면 아무것도 지우지 않고 멈춘다.
//

import Foundation
import Observation

@MainActor
@Observable
final class AccountStore {
    enum State: Equatable {
        /// Firebase를 쓸 수 없다(plist 없음). PLAYER 박스를 숨긴다.
        case unavailable
        case signedOut
        case signingIn(AccountMethod)
        /// 로그인됐고 프로필을 읽는 중.
        case loading
        /// 로그인됐지만 프로필이 없다(첫 로그인, 또는 삭제가 중간에 실패).
        case needsProfile
        case signedIn(PlayerProfile)
        /// 로그인됐지만 프로필을 읽지 못했다(네트워크 등) — 다시 시도.
        case loadFailed
        case deleting
    }

    /// 한 번 보여주고 지우는 안내(충돌·실패). 문구는 L10n이 고른다.
    enum Notice: Equatable {
        case loginFailed
        case googleUnavailable
        case existsWithDifferentMethod
        case alreadyInUse
        case linkFailed
        case linked(AccountMethod)
        case saveFailed
        case deleteFailed
        case revokeFailed
    }

    /// 프로필 저장 결과. 입력 오류는 화면에 바로 표시하고, 전송 실패는 notice로 알린다.
    enum SaveOutcome: Equatable {
        case saved
        case invalid(NicknameError)
        case failed
    }

    private(set) var state: State
    /// 연결된 로그인 방법.
    private(set) var methods: [AccountMethod] = []
    /// 서버 쓰기 진행 중(버튼 비활성).
    private(set) var isWorking = false
    /// 운영자 계정인지(커스텀 클레임). 운영자는 고른 아바타와 무관하게 전용 아바타로 보인다.
    private(set) var isOperator = false
    var notice: Notice?

    @ObservationIgnored private let auth: AccountAuthenticating
    @ObservationIgnored private let profiles: PlayerProfileClient?
    @ObservationIgnored private let isDemo: () -> Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var currentUID: String?
    /// 계정 삭제가 끝나면 그 uid로 부른다(몬스터 기록 정리 — 앱이 연결한다).
    @ObservationIgnored var onAccountDeleted: ((String) -> Void)?
    /// 마지막으로 서버에서 다시 읽은 시각(`revalidate()` 간격 판단용).
    @ObservationIgnored private var lastRefreshAt: Date?

    /// 앱에서 쓰는 실제 구성(FirebaseAuth + 번들 plist의 프로젝트).
    static func live(isDemo: @escaping () -> Bool) -> AccountStore {
        AccountStore(auth: FirebaseAccountAuth(), projectID: PlayerProfileClient.bundledProjectID(), isDemo: isDemo)
    }

    /// 미리보기용 — 계정 기능이 꺼진 상태(PLAYER 박스 숨김).
    static func disabled() -> AccountStore {
        AccountStore(auth: UnavailableAccountAuth(), projectID: nil)
    }

    init(auth: AccountAuthenticating,
         projectID: String?,
         transport: PlayerProfileClient.Transport? = nil,
         isDemo: @escaping () -> Bool = { false },
         defaults: UserDefaults = .standard) {
        self.auth = auth
        self.isDemo = isDemo
        self.defaults = defaults
        if auth.isAvailable, let projectID {
            let token: PlayerProfileClient.TokenProvider = { [weak auth] force in
                await auth?.idToken(forceRefresh: force)
            }
            profiles = transport.map { PlayerProfileClient(projectID: projectID, token: token, transport: $0) }
                ?? PlayerProfileClient(projectID: projectID, token: token)
            state = .signedOut
            restoreFromCache()
        } else {
            profiles = nil
            state = .unavailable
        }
    }

    var isAvailable: Bool { state != .unavailable }
    var isGoogleAvailable: Bool { auth.isGoogleAvailable }

    var profile: PlayerProfile? {
        if case .signedIn(let p) = state { return p }
        return nil
    }

    /// 로그인한 계정 uid(프로필 유무와 무관). 몬스터 서버 판정·기기 세션 장부가 쓴다.
    var uid: String? { currentUID }

    /// 몬스터 서버 호출용 ID 토큰(요청 직전에 받아 헤더에만 싣는다). 데모 중이면 nil.
    func idToken(forceRefresh: Bool) async -> String? {
        guard !isDemo() else { return nil }
        return await auth.idToken(forceRefresh: forceRefresh)
    }

    /// 몬스터 기능 동의(약관 v2)를 서버에 기록한 뒤 화면 상태에 반영한다.
    func markTermsAccepted(version: Int) {
        guard case .signedIn(var p) = state, p.termsAcceptedVersion < version else { return }
        p.termsAcceptedVersion = version
        state = .signedIn(p)
    }

    /// 화면에 그릴 아바타. 운영자면 전용 아바타(번들에 있을 때), 아니면 고른 아바타.
    func displayAvatarID(for profile: PlayerProfile) -> String {
        if isOperator, let id = AvatarCatalog.operatorAvatar?.id { return id }
        return profile.avatarID
    }

    /// 다음 닉네임 변경까지 남은 밀리초(0이면 지금 가능). 서버 시차 보정 시각 기준.
    var nicknameCooldownRemainingMs: Int64 {
        guard let profile, let profiles else { return 0 }
        return NicknamePolicy.cooldownRemainingMs(lastChangedAtMs: profile.nicknameChangedAtMs,
                                                  nowMs: profiles.nowMs)
    }

    // MARK: 시작·복원

    /// 앱 시작 시 1회. 로그인 상태 변화를 구독하고, 로그인돼 있으면 프로필을 서버에서 다시 읽는다.
    func start() {
        guard isAvailable else { return }
        auth.startListening { [weak self] user in
            self?.authChanged(user)
        }
        if let user = auth.currentUser {
            currentUID = user.uid
            methods = user.methods
            Task { await refreshProfile() }
        }
    }

    /// 캐시가 지금 로그인한 계정 것이면 즉시 그린다(서버 응답 전 깜빡임 방지).
    private func restoreFromCache() {
        guard let user = auth.currentUser else {
            PlayerProfileCache.clear(in: defaults)
            return
        }
        currentUID = user.uid
        methods = user.methods
        if let cache = PlayerProfileCache.load(from: defaults), cache.uid == user.uid {
            state = .signedIn(PlayerProfile(
                nickname: cache.nickname, nicknameLower: NicknamePolicy.lower(cache.nickname), tag: cache.tag,
                nicknameChangedAtMs: cache.nicknameChangedAtMs, avatarID: cache.avatarId,
                termsAcceptedVersion: PlayerProfile.currentTermsVersion,
                createdAtMs: cache.nicknameChangedAtMs, updatedAtMs: cache.nicknameChangedAtMs))
        } else {
            state = .loading
        }
    }

    private func authChanged(_ user: AccountUser?) {
        guard let user else {
            // 만료·다른 경로 로그아웃. 삭제 흐름은 스스로 정리한다.
            guard state != .deleting else { return }
            currentUID = nil
            methods = []
            isOperator = false
            PlayerProfileCache.clear(in: defaults)
            if state != .unavailable { state = .signedOut }
            return
        }
        methods = user.methods
        // 로그인 흐름(signIn)이 직접 프로필을 읽는다 — 리스너가 겹쳐 읽지 않게 한다.
        guard user.uid != currentUID, !isSigningIn, state != .deleting else { return }
        currentUID = user.uid
        Task { await refreshProfile() }
    }

    private var isSigningIn: Bool {
        if case .signingIn = state { return true }
        return false
    }

    /// PLAYER 박스가 보일 때 부른다. 웹·다른 기기에서 계정을 지웠거나 프로필을 바꿨으면 반영한다.
    /// 설정을 여닫을 때마다 서버를 부르지 않게, 마지막 확인 뒤 일정 시간 안에는 건너뛴다.
    func revalidate() async {
        guard currentUID != nil, !isWorking, !isSigningIn, state != .deleting else { return }
        if let last = lastRefreshAt, Date().timeIntervalSince(last) < Self.revalidateInterval { return }
        await refreshProfile()
    }

    /// `revalidate()`가 다시 확인하기까지의 최소 간격(초).
    private static let revalidateInterval: TimeInterval = 30

    /// 서버에서 프로필을 다시 읽는다. 이미 보이는 프로필이 있으면 실패해도 그대로 둔다.
    /// 계정이 서버에서 지워졌으면(웹·다른 기기에서 삭제) 이 기기도 로그아웃 상태로 정리한다.
    func refreshProfile() async {
        guard !isDemo(), let profiles, let user = auth.currentUser else { return }
        lastRefreshAt = Date()
        if profile == nil { state = .loading }
        if await auth.reloadUser() == .revoked {
            auth.signOut()
            resetLocal()
            return
        }
        // 클레임은 새 토큰에만 실린다 — 프로필을 읽을 때(시작·로그인) 토큰을 새로 받아 운영자 여부를 갱신한다.
        isOperator = await auth.isOperator(forceRefresh: true)
        switch await profiles.fetchProfile(uid: user.uid) {
        case .found(let p):
            apply(p, uid: user.uid)
        case .notFound:
            PlayerProfileCache.clear(in: defaults)
            state = .needsProfile
        case .failed:
            if profile == nil { state = .loadFailed }
        }
    }

    // MARK: 로그인·연결·로그아웃

    func signIn(with method: AccountMethod) async {
        guard !isDemo(), isAvailable, state == .signedOut || state == .loadFailed else { return }
        state = .signingIn(method)
        let result = await auth.signIn(with: method)
        switch result {
        case .success(let user, let isNew):
            AnalyticsService.shared.log(.accountLogin(method: method, isNew: isNew))
            currentUID = user.uid
            methods = user.methods
            state = .loading
            await refreshProfile()
        case .cancelled:
            state = .signedOut
            AnalyticsService.shared.log(.accountLoginFail(method: method, stage: .cancel))
        case .unavailable:
            state = .signedOut
            notice = .googleUnavailable
            AnalyticsService.shared.log(.accountLoginFail(method: method, stage: .provider))
        case .failed(let stage):
            state = .signedOut
            notice = .loginFailed
            AnalyticsService.shared.log(.accountLoginFail(method: method, stage: stage))
        case .existsWithDifferentMethod, .alreadyInUse:
            state = .signedOut
            notice = .existsWithDifferentMethod
            AnalyticsService.shared.log(.accountLoginFail(method: method, stage: .conflict))
        }
    }

    func link(_ method: AccountMethod) async {
        guard !isDemo(), currentUID != nil, !methods.contains(method), !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        switch await auth.link(method) {
        case .success(let user, _):
            methods = user.methods
            notice = .linked(method)
            AnalyticsService.shared.log(.accountLink(method: method))
        case .cancelled:
            break
        case .unavailable:
            notice = .googleUnavailable
        case .existsWithDifferentMethod, .alreadyInUse:
            notice = .alreadyInUse
        case .failed:
            notice = .linkFailed
        }
    }

    func signOut() {
        guard !isDemo(), currentUID != nil, state != .deleting else { return }
        auth.signOut()
        resetLocal()
        AnalyticsService.shared.log(.accountLogout)
    }

    private func resetLocal() {
        currentUID = nil
        methods = []
        isOperator = false
        PlayerProfileCache.clear(in: defaults)
        state = .signedOut
    }

    // MARK: 프로필

    /// 첫 프로필 저장. 배틀태그를 무작위로 뽑아 예약과 프로필 생성을 한 커밋으로 보낸다.
    func createProfile(nickname raw: String, avatarID: String, termsAccepted: Bool) async -> SaveOutcome {
        guard !isDemo(), state == .needsProfile, let profiles, let uid = currentUID, !isWorking else { return .failed }
        let nickname = NicknamePolicy.normalize(raw)
        if let error = NicknamePolicy.validate(nickname) { return .invalid(error) }
        guard termsAccepted else { return .invalid(.termsRequired) }
        let lower = NicknamePolicy.lower(nickname)
        isWorking = true
        defer { isWorking = false }
        await profiles.ensureServerTime(uid: uid)
        for _ in 0..<Self.tagAttempts {
            let tag = NicknamePolicy.randomTag()
            let key = NicknamePolicy.nametagKey(lower: lower, tag: tag)
            switch await profiles.nametagAvailability(key: key, uid: uid) {
            case .taken: continue
            case .failed: notice = .saveFailed; return .failed
            case .available: break
            }
            let now = profiles.nowMs
            let profile = PlayerProfile(nickname: nickname, nicknameLower: lower, tag: tag, nicknameChangedAtMs: now,
                                        avatarID: avatarID, termsAcceptedVersion: PlayerProfile.currentTermsVersion,
                                        createdAtMs: now, updatedAtMs: now)
            switch await profiles.commit(profiles.documents.create(uid: uid, profile: profile),
                                         uid: uid, nametagKey: key) {
            case .ok:
                apply(profile, uid: uid)
                return .saved
            case .taken:
                continue   // 그 사이 다른 계정이 같은 태그를 잡았다 — 다시 뽑는다
            case .failed:
                notice = .saveFailed
                return .failed
            }
        }
        return .invalid(.taken)   // 같은 닉네임의 태그가 거의 다 찼다(사실상 일어나지 않음)
    }

    /// 태그를 다시 뽑는 최대 횟수.
    private static let tagAttempts = 6

    /// 닉네임 변경(30일에 1회). 바꿀 때마다 배틀태그를 새로 뽑는다(이전 태그와 다르게).
    func changeNickname(_ raw: String) async -> SaveOutcome {
        guard !isDemo(), let current = profile, let profiles, let uid = currentUID, !isWorking else { return .failed }
        let nickname = NicknamePolicy.normalize(raw)
        if nickname == current.nickname { return .saved }
        if let error = NicknamePolicy.validate(nickname) { return .invalid(error) }
        isWorking = true
        defer { isWorking = false }
        await profiles.ensureServerTime(uid: uid)
        if nicknameCooldownRemainingMs > 0 { return .invalid(.cooldown) }
        let lower = NicknamePolicy.lower(nickname)
        for _ in 0..<Self.tagAttempts {
            let tag = NicknamePolicy.randomTag(excluding: current.tag)
            let key = NicknamePolicy.nametagKey(lower: lower, tag: tag)
            switch await profiles.nametagAvailability(key: key, uid: uid) {
            case .taken: continue
            case .failed: notice = .saveFailed; return .failed
            case .available: break
            }
            let now = profiles.nowMs
            let writes = profiles.documents.changeNickname(uid: uid, oldKey: current.nametagKey, nickname: nickname,
                                                           lower: lower, tag: tag, nowMs: now)
            switch await profiles.commit(writes, uid: uid, nametagKey: key) {
            case .ok:
                var updated = current
                updated.nickname = nickname
                updated.nicknameLower = lower
                updated.tag = tag
                updated.nicknameChangedAtMs = now
                updated.updatedAtMs = now
                apply(updated, uid: uid)
                AnalyticsService.shared.log(.profileUpdate(field: .nickname))
                return .saved
            case .taken:
                continue
            case .failed:
                notice = .saveFailed
                return .failed
            }
        }
        return .invalid(.taken)
    }

    func changeAvatar(_ avatarID: String) async -> SaveOutcome {
        guard !isDemo(), let current = profile, let profiles, let uid = currentUID, !isWorking else { return .failed }
        if avatarID == current.avatarID { return .saved }
        isWorking = true
        defer { isWorking = false }
        await profiles.ensureServerTime(uid: uid)
        let now = profiles.nowMs
        switch await profiles.commit(profiles.documents.changeAvatar(uid: uid, avatarID: avatarID, nowMs: now),
                                     uid: uid) {
        case .ok:
            var updated = current
            updated.avatarID = avatarID
            updated.updatedAtMs = now
            apply(updated, uid: uid)
            AnalyticsService.shared.log(.profileUpdate(field: .avatar))
            return .saved
        case .taken, .failed:
            notice = .saveFailed
            return .failed
        }
    }

    private func apply(_ profile: PlayerProfile, uid: String) {
        state = .signedIn(profile)
        PlayerProfileCache(uid: uid, nickname: profile.nickname, tag: profile.tag, avatarId: profile.avatarID,
                           nicknameChangedAtMs: profile.nicknameChangedAtMs).save(to: defaults)
    }

    // MARK: 삭제

    /// 계정 삭제(앱 안). 프로필이 없으면(needsProfile) 커밋 없이 Auth 사용자만 지운다.
    func deleteAccount() async {
        guard !isDemo(), let profiles, let uid = currentUID, state != .deleting, !isWorking else { return }
        let previous = state
        state = .deleting
        switch await auth.reauthenticateForDeletion() {
        case .ok: break
        case .cancelled: state = previous; return
        case .failed: state = previous; notice = .deleteFailed; return
        case .revokeFailed: state = previous; notice = .revokeFailed; return
        }
        if case .signedIn(let p) = previous {
            let writes = profiles.documents.delete(uid: uid, nametagKey: p.nametagKey)
            guard await profiles.commit(writes, uid: uid) == .ok else {
                state = previous
                notice = .deleteFailed
                return
            }
        }
        guard await auth.deleteUser() else {
            // 프로필은 지워졌고 Auth 사용자만 남았다 — 다음에는 프로필 설정부터 시작한다. 재시도를 안내한다.
            PlayerProfileCache.clear(in: defaults)
            state = .needsProfile
            notice = .deleteFailed
            return
        }
        resetLocal()
        onAccountDeleted?(uid)
        AnalyticsService.shared.log(.accountDelete)
    }
}

/// Firebase가 없는 구성(미리보기). 모든 동작이 실패로 끝난다.
@MainActor
final class UnavailableAccountAuth: AccountAuthenticating {
    var isAvailable: Bool { false }
    var isGoogleAvailable: Bool { false }
    var currentUser: AccountUser? { nil }
    func startListening(_ onChange: @escaping (AccountUser?) -> Void) {}
    func reloadUser() async -> AccountSessionStatus { .unknown }
    func signIn(with method: AccountMethod) async -> AccountAuthResult { .unavailable }
    func link(_ method: AccountMethod) async -> AccountAuthResult { .unavailable }
    func reauthenticateForDeletion() async -> AccountReauthResult { .failed }
    func deleteUser() async -> Bool { false }
    func signOut() {}
    func idToken(forceRefresh: Bool) async -> String? { nil }
    func isOperator(forceRefresh: Bool) async -> Bool { false }
}
