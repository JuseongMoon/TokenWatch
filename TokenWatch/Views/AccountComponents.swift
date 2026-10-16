//
//  AccountComponents.swift
//  TokenWatch
//
//  앱 계정 화면 공용 부품: 로그인 브랜드 버튼(Apple·Google), 아바타 선택 격자, 닉네임 입력칸, 안내 줄.
//
//  로그인 버튼은 터미널 테마의 예외다. Apple은 시스템 `ASAuthorizationAppleIDButton`(검은 배경 → 흰색 스타일),
//  Google은 Apple 버튼과 톤앤매너를 맞춘 흰 버튼(공식 G 로고 + 문구, DronePass 로그인 버튼과 같은 구성)이다.
//  두 버튼은 같은 높이·모서리·글자 크기로 둔다. 문구는 영어 고정이다 — 앱이 영어 지역화만 갖고 있어
//  Apple 버튼이 기기 언어와 무관하게 영어로 그려지므로 Google 쪽도 맞춘다(Android도 영어 고정).
//  버튼은 탭만 전달하고, 로그인 흐름은 AccountStore가 직접 띄운다(연결·재인증과 같은 경로).
//

import AuthenticationServices
import SwiftUI

/// 로그인 버튼 높이·모서리(두 버튼 공통).
let accountBrandButtonHeight: CGFloat = 50
let accountBrandButtonCorner: CGFloat = 12

struct AppleSignInButton: UIViewRepresentable {
    var type: ASAuthorizationAppleIDButton.ButtonType = .signIn
    let action: () -> Void

    func makeCoordinator() -> TapTarget { TapTarget(action: action) }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(authorizationButtonType: type, authorizationButtonStyle: .white)
        button.cornerRadius = accountBrandButtonCorner
        button.addTarget(context.coordinator, action: #selector(TapTarget.tap), for: .touchUpInside)
        return button
    }

    func updateUIView(_ view: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action
        view.isEnabled = context.environment.isEnabled   // SwiftUI .disabled는 UIKit 컨트롤에 전해지지 않는다
    }
}

/// Apple 흰색 버튼과 같은 모양의 Google 버튼 — 흰 배경, 공식 컬러 G 로고(`GoogleLogo` 에셋), 검정 semibold 문구.
struct GoogleSignInButton: View {
    /// 로그인 화면은 "Sign in", 연결(Apple `.continue`와 짝)은 "Continue".
    var continueStyle = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image("GoogleLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                Text(continueStyle ? "Continue with Google" : "Sign in with Google")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: accountBrandButtonHeight)
            .background(RoundedRectangle(cornerRadius: accountBrandButtonCorner).fill(.white))
            .contentShape(RoundedRectangle(cornerRadius: accountBrandButtonCorner))
        }
        .buttonStyle(BrandPressStyle())
    }
}

/// 누르는 동안 살짝 흐려지는 정도의 반응(시스템 Apple 버튼과 비슷하게).
private struct BrandPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.75 : 1)
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
            }
            if showGoogle {
                GoogleSignInButton(continueStyle: appleType == .continue, action: onGoogle)
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

#Preview("login buttons") {
    VStack(spacing: 24) {
        AccountBrandButtons(showApple: true, showGoogle: true, disabled: false, onApple: {}, onGoogle: {})
        AccountBrandButtons(appleType: .continue, showApple: true, showGoogle: true, disabled: false,
                            onApple: {}, onGoogle: {})
    }
    .padding(16)
    .background(Term.bg)
}
