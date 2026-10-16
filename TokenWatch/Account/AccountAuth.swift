//
//  AccountAuth.swift
//  TokenWatch
//
//  앱 계정 인증 계층. FirebaseAuth(인증만 SDK — Firestore는 REST)와 Apple·Google 로그인 흐름을 감싼다.
//  AccountStore는 `AccountAuthenticating`에만 의존해 Firebase 없이도 상태 전이를 테스트할 수 있다.
//
//  토큰 보관: 앱 코드는 Firebase·Apple·Google 토큰을 저장하지 않는다. FirebaseAuth·GoogleSignIn이 각자
//  Keychain에 보관한다. ID 토큰은 요청 직전에 받아 헤더에만 싣는다.
//  수집 최소화: Apple 로그인은 이메일·이름 범위를 요청하지 않는다. 앱은 Auth 레코드의 이름·사진을 쓰지 않는다.
//

import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseCore
import GoogleSignIn
import UIKit

/// 로그인된 앱 계정의 최소 정보(이메일·이름은 다루지 않는다).
nonisolated struct AccountUser: Equatable, Sendable {
    let uid: String
    /// 연결된 로그인 방법(Apple·Google). 순서는 `AccountMethod.allCases`.
    let methods: [AccountMethod]
}

/// 앱 계정 로그인 실패 단계. 분석 파라미터 `stage` 값이다(계약 §7).
nonisolated enum AccountFailStage: String, Sendable {
    case cancel
    case provider
    case firebase
    case conflict
}

enum AccountAuthResult: Equatable {
    case success(AccountUser, isNew: Bool)
    case cancelled
    /// 이 기기·빌드에서 그 방법을 쓸 수 없다(Google 클라이언트 설정 없음 등).
    case unavailable
    case failed(AccountFailStage)
    /// 로그인: 같은 이메일이 다른 방법으로 가입돼 있다 → 그 방법으로 로그인한 뒤 연결.
    case existsWithDifferentMethod
    /// 연결: 그 로그인이 이미 다른 TokenWatch 계정에 묶여 있다(병합하지 않는다).
    case alreadyInUse
}

enum AccountReauthResult: Equatable {
    case ok
    case cancelled
    case failed
    /// 재인증은 됐지만 Apple 토큰 폐기가 실패했다 — 삭제를 중단한다(서버만으로는 나중에 폐기할 수 없다).
    case revokeFailed
}

@MainActor
protocol AccountAuthenticating: AnyObject {
    /// Firebase가 구성됐는지(plist 있음). false면 계정 기능 전체를 숨긴다.
    var isAvailable: Bool { get }
    var isGoogleAvailable: Bool { get }
    var currentUser: AccountUser? { get }
    /// 로그인 상태 변화(복원·만료·로그아웃) 구독. 앱 수명 동안 한 번 건다.
    func startListening(_ onChange: @escaping (AccountUser?) -> Void)
    func signIn(with method: AccountMethod) async -> AccountAuthResult
    func link(_ method: AccountMethod) async -> AccountAuthResult
    /// 계정 삭제 직전 재인증. Apple이 연결돼 있으면 Apple로 재인증하고 토큰을 폐기한다.
    func reauthenticateForDeletion() async -> AccountReauthResult
    func deleteUser() async -> Bool
    func signOut()
    func idToken(forceRefresh: Bool) async -> String?
}

// MARK: - Firebase 구현

@MainActor
final class FirebaseAccountAuth: AccountAuthenticating {
    private var listener: AuthStateDidChangeListenerHandle?

    var isAvailable: Bool { FirebaseApp.app() != nil }
    var isGoogleAvailable: Bool { isAvailable && GoogleSignInFlow.isConfigured }

    var currentUser: AccountUser? {
        guard isAvailable, let user = Auth.auth().currentUser else { return nil }
        return Self.accountUser(user)
    }

    func startListening(_ onChange: @escaping (AccountUser?) -> Void) {
        guard isAvailable, listener == nil else { return }
        listener = Auth.auth().addStateDidChangeListener { _, user in
            onChange(user.map(Self.accountUser))
        }
    }

    func signIn(with method: AccountMethod) async -> AccountAuthResult {
        let credential: AuthCredential
        switch await makeCredential(for: method) {
        case .credential(let c, _): credential = c
        case .cancelled: return .cancelled
        case .unavailable: return .unavailable
        case .failed: return .failed(.provider)
        }
        do {
            let result = try await Auth.auth().signIn(with: credential)
            return .success(Self.accountUser(result.user), isNew: result.additionalUserInfo?.isNewUser ?? false)
        } catch {
            return Self.mapError(error)
        }
    }

    func link(_ method: AccountMethod) async -> AccountAuthResult {
        guard let user = Auth.auth().currentUser else { return .failed(.firebase) }
        let credential: AuthCredential
        switch await makeCredential(for: method) {
        case .credential(let c, _): credential = c
        case .cancelled: return .cancelled
        case .unavailable: return .unavailable
        case .failed: return .failed(.provider)
        }
        do {
            let result = try await user.link(with: credential)
            return .success(Self.accountUser(result.user), isNew: false)
        } catch {
            // 연결에서는 두 충돌 모두 "다른 계정에 묶여 있음"이다(병합 없음).
            let mapped = Self.mapError(error)
            return mapped == .existsWithDifferentMethod ? .alreadyInUse : mapped
        }
    }

    func reauthenticateForDeletion() async -> AccountReauthResult {
        guard let user = Auth.auth().currentUser else { return .failed }
        let methods = Self.accountUser(user).methods
        let method: AccountMethod = methods.contains(.apple) || methods.isEmpty ? .apple : .google
        let credential: AuthCredential
        let appleCode: String?
        switch await makeCredential(for: method) {
        case .credential(let c, let code): credential = c; appleCode = code
        case .cancelled: return .cancelled
        case .unavailable, .failed: return .failed
        }
        do {
            _ = try await user.reauthenticate(with: credential)
        } catch {
            return Self.mapError(error) == .cancelled ? .cancelled : .failed
        }
        guard method == .apple else { return .ok }
        // Apple 계정 연결 해제(설정 > Apple ID > "Apple로 로그인" 목록에서 사라짐). 실패하면 삭제를 멈춘다.
        guard let appleCode else { return .revokeFailed }
        do {
            try await Auth.auth().revokeToken(withAuthorizationCode: appleCode)
            return .ok
        } catch {
            return .revokeFailed
        }
    }

    func deleteUser() async -> Bool {
        guard let user = Auth.auth().currentUser else { return false }
        do {
            try await user.delete()
            GIDSignIn.sharedInstance.signOut()
            return true
        } catch {
            return false
        }
    }

    func signOut() {
        try? Auth.auth().signOut()
        GIDSignIn.sharedInstance.signOut()
    }

    func idToken(forceRefresh: Bool) async -> String? {
        guard isAvailable, let user = Auth.auth().currentUser else { return nil }
        return try? await user.getIDToken(forcingRefresh: forceRefresh)
    }

    // MARK: 자격증명

    private enum CredentialOutcome {
        /// appleAuthorizationCode: Apple 토큰 폐기용(재인증 때만 쓴다).
        case credential(AuthCredential, appleAuthorizationCode: String?)
        case cancelled
        case unavailable
        case failed
    }

    private func makeCredential(for method: AccountMethod) async -> CredentialOutcome {
        switch method {
        case .apple:
            switch await AppleSignInFlow().run() {
            case .success(let r):
                // 이름은 넘기지 않는다 — 앱은 Auth 레코드의 displayName을 쓰지 않는다(실명 저장 회피).
                let c = OAuthProvider.appleCredential(withIDToken: r.idToken, rawNonce: r.rawNonce, fullName: nil)
                return .credential(c, appleAuthorizationCode: r.authorizationCode)
            case .cancelled: return .cancelled
            case .failed: return .failed
            }
        case .google:
            switch await GoogleSignInFlow.run() {
            case .success(let idToken, let accessToken):
                return .credential(GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken),
                                   appleAuthorizationCode: nil)
            case .cancelled: return .cancelled
            case .unavailable: return .unavailable
            case .failed: return .failed
            }
        }
    }

    private static func accountUser(_ user: User) -> AccountUser {
        let ids = Set(user.providerData.map(\.providerID))
        return AccountUser(uid: user.uid,
                           methods: AccountMethod.allCases.filter { ids.contains($0.firebaseProviderID) })
    }

    /// Firebase 오류 → 결과. 원문 메시지는 쓰지 않는다.
    private static func mapError(_ error: Error) -> AccountAuthResult {
        switch AuthErrorCode(rawValue: (error as NSError).code) {
        case .accountExistsWithDifferentCredential: return .existsWithDifferentMethod
        case .credentialAlreadyInUse: return .alreadyInUse
        case .webContextCancelled: return .cancelled
        default: return .failed(.firebase)
        }
    }
}

// MARK: - Sign in with Apple

/// ASAuthorizationController 한 번을 async로 감싼다. 진행 중에는 컨트롤러를 강하게 붙잡는다.
@MainActor
final class AppleSignInFlow: NSObject, ASAuthorizationControllerDelegate,
                             ASAuthorizationControllerPresentationContextProviding {
    struct Result {
        let idToken: String
        let rawNonce: String
        let authorizationCode: String?
    }

    enum Outcome {
        case success(Result)
        case cancelled
        case failed
    }

    private var continuation: CheckedContinuation<Outcome, Never>?
    private var controller: ASAuthorizationController?
    private var rawNonce = ""

    func run() async -> Outcome {
        rawNonce = Self.randomNonce()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = []   // 이메일·이름을 받지 않는다
        request.nonce = Self.sha256Hex(rawNonce)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            finish(.failed)
            return
        }
        let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        finish(.success(Result(idToken: idToken, rawNonce: rawNonce, authorizationCode: code)))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        finish((error as? ASAuthorizationError)?.code == .canceled ? .cancelled : .failed)
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.foregroundKeyWindow ?? ASPresentationAnchor()
    }

    private func finish(_ outcome: Outcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
        controller = nil
    }

    /// 재전송 공격 방지용 일회성 문자열. 요청에는 SHA-256을 싣고 Firebase에는 원문을 준다.
    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in charset.randomElement(using: &rng)! })
    }

    private static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Google Sign-In

/// GIDSignIn 래퍼. ASWebAuthenticationSession(앱 위 시스템 시트)으로 띄운다 — 외부 Safari로 보내지 않는다.
enum GoogleSignInFlow {
    enum Outcome {
        case success(idToken: String, accessToken: String)
        case cancelled
        case unavailable
        case failed
    }

    /// Firebase 콘솔에서 Google 제공자를 켜고 plist를 다시 받아야 생기는 iOS OAuth 클라이언트 ID.
    static var clientID: String? { FirebaseApp.app()?.options.clientID }

    /// 클라이언트 ID가 있고, 그 역순 ID가 Info.plist URL 스킴으로 등록돼 있을 때만 쓸 수 있다.
    /// (스킴이 없으면 GIDSignIn이 예외로 앱을 멈춘다 — 그래서 미리 확인한다.)
    static var isConfigured: Bool {
        guard let clientID else { return false }
        let reversed = clientID.split(separator: ".").reversed().joined(separator: ".")
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        return types.contains { ($0["CFBundleURLSchemes"] as? [String] ?? []).contains(reversed) }
    }

    @MainActor
    static func run() async -> Outcome {
        guard isConfigured, let clientID,
              let presenter = UIApplication.shared.topViewControllerForPresentation else { return .unavailable }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString else { return .failed }
            return .success(idToken: idToken, accessToken: result.user.accessToken.tokenString)
        } catch {
            return (error as? GIDSignInError)?.code == .canceled ? .cancelled : .failed
        }
    }

    /// 로그인 시트의 URL 콜백. 처리했으면 true.
    @MainActor
    static func handle(_ url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }
}
