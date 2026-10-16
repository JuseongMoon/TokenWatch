//
//  AccountComponents.swift
//  TokenWatch
//
//  앱 계정 화면 공용 부품: 로그인 브랜드 버튼(Apple·Google), 아바타 선택 격자, 닉네임 입력칸, 안내 줄.
//
//  로그인 버튼은 터미널 테마의 예외다. Apple은 시스템 `ASAuthorizationAppleIDButton`(검은 배경 → 흰색 스타일),
//  Google은 SDK의 공식 `GIDSignInButton`(흰색)을 쓴다 — 두 버튼을 같은 높이·같은 눈에 띄는 정도로 둔다.
//  버튼은 탭만 전달하고, 로그인 흐름은 AccountStore가 직접 띄운다(연결·재인증과 같은 경로).
//

import AuthenticationServices
import GoogleSignIn
import SwiftUI

/// 로그인 버튼 높이(두 버튼 공통).
let accountBrandButtonHeight: CGFloat = 48

struct AppleSignInButton: UIViewRepresentable {
    var type: ASAuthorizationAppleIDButton.ButtonType = .signIn
    let action: () -> Void

    func makeCoordinator() -> TapTarget { TapTarget(action: action) }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(authorizationButtonType: type, authorizationButtonStyle: .white)
        button.cornerRadius = 6
        button.addTarget(context.coordinator, action: #selector(TapTarget.tap), for: .touchUpInside)
        return button
    }

    func updateUIView(_ view: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action
        view.isEnabled = context.environment.isEnabled   // SwiftUI .disabled는 UIKit 컨트롤에 전해지지 않는다
    }
}

struct GoogleSignInButton: UIViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> TapTarget { TapTarget(action: action) }

    func makeUIView(context: Context) -> GIDSignInButton {
        let button = GIDSignInButton()
        button.style = .wide
        button.colorScheme = .light
        button.addTarget(context.coordinator, action: #selector(TapTarget.tap), for: .touchUpInside)
        return button
    }

    func updateUIView(_ view: GIDSignInButton, context: Context) {
        context.coordinator.action = action
        view.isEnabled = context.environment.isEnabled
    }
}

/// UIKit 버튼의 target-action을 SwiftUI 클로저로 잇는다.
final class TapTarget: NSObject {
    var action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func tap() { action() }
}

/// 로그인 버튼 두 개(Apple 먼저). Google을 쓸 수 없는 빌드면 Google 버튼을 숨긴다.
struct AccountBrandButtons: View {
    var appleType: ASAuthorizationAppleIDButton.ButtonType = .signIn
    let showApple: Bool
    let showGoogle: Bool
    let disabled: Bool
    let onApple: () -> Void
    let onGoogle: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if showApple {
                AppleSignInButton(type: appleType, action: onApple)
                    .frame(height: accountBrandButtonHeight)
                    .accessibilityLabel("Sign in with Apple")
            }
            if showGoogle {
                GoogleSignInButton(action: onGoogle)
                    .frame(height: accountBrandButtonHeight)
                    .accessibilityLabel("Sign in with Google")
            }
        }
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

/// 아바타 선택 격자(4열, 1칸 64pt). 선택된 칸은 초록 테두리 + `>` 커서.
struct AvatarPicker: View {
    @Binding var selection: String
    let lang: Lang

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(AvatarCatalog.all) { avatar in
                let selected = avatar.id == selection
                Button {
                    selection = avatar.id
                } label: {
                    AvatarView(avatarID: avatar.id, cell: 4)
                        .padding(5)
                        .frame(maxWidth: .infinity)
                        .overlay(Rectangle().stroke(selected ? Term.green : Term.dim.opacity(0.5),
                                                    lineWidth: selected ? 2 : 1))
                        .overlay(alignment: .topLeading) {
                            if selected {
                                Text(">")
                                    .font(.term(11, weight: .bold))
                                    .foregroundStyle(Term.green)
                                    .padding(.leading, 3)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(avatar.name(lang))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// 닉네임 입력칸(터미널 스타일). 검증은 저장할 때 한다 — 한글 조합 중인 글자를 검사하지 않기 위해서다.
struct NicknameField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(Term.dim))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .textContentType(.nickname)
            .font(.term(14))
            .foregroundStyle(Term.fg)
            .tint(Term.green)
            .padding(12)
            .overlay(Rectangle().stroke(Term.dim.opacity(0.5), lineWidth: 1))
    }
}

/// 한 줄 안내(오류는 빨강, 완료는 초록).
struct AccountNoticeLine: View {
    let text: String
    var color: Color = Term.red

    var body: some View {
        Text(text)
            .font(.term(11))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension AccountStore.Notice {
    /// 완료 안내(초록)인지.
    var isPositive: Bool {
        if case .linked = self { return true }
        return false
    }
}
