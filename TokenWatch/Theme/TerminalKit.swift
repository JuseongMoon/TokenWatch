//
//  TerminalKit.swift
//  TokenWatch
//
//  터미널 UI 공용 레이아웃 조각: 罫선 박스 · 프롬프트 버튼 · 키:값 행.
//  모서리(┌┐└┘)는 진짜 문자로, 변(─│)은 반응형을 위해 1px Rectangle로 근사한다.
//

import SwiftUI

/// 罫선 스타일 박스 컨테이너.
/// 테두리는 `Rectangle().stroke`로 그려 항상 정확한 사각형을 보장하고,
/// 타이틀은 상단 변 위에 배경색으로 얹어 `── TITLE ──`처럼 변을 끊는다.
struct TerminalBox<Content: View>: View {
    var title: String? = nil
    var titleColor: Color = Term.cyan
    var borderColor: Color = Term.dim
    var contentPadding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 제목은 박스 안 첫 줄에 둔다 — 상단 테두리 선과 겹치지 않는다.
            if let title {
                Text(title)
                    .font(.term(12, weight: .semibold))
                    .foregroundStyle(titleColor)
                    .terminalGlow(titleColor, radius: 2)
                    .lineLimit(1)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(contentPadding)
        .overlay(Rectangle().stroke(borderColor, lineWidth: 1.5))   // 온전한 사각형 테두리
        .font(.term(13))
        .background(Term.bg)
    }
}

/// iOS 26 툴바의 Liquid Glass 공유 배경(알약/원형)을 제거한 툴바 아이템.
/// 터미널 테마는 텍스트만 노출해야 하므로 `sharedBackgroundVisibility(.hidden)`로 배경을 끈다.
/// 해당 API는 iOS 26+ 전용이라, 그 이하에서는 일반 `ToolbarItem`과 동일하게 동작한다.
struct PlainToolbarItem<Content: View>: ToolbarContent {
    var placement: ToolbarItemPlacement = .automatic
    @ViewBuilder var content: () -> Content

    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: placement) { content() }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: placement) { content() }
        }
    }
}

/// 프롬프트형 버튼. title에 `[ + ADD ]`, `❯ add agent_` 같은 텍스트를 그대로 전달한다.
struct TerminalButton: View {
    let title: String
    var color: Color = Term.green
    var dashedBorder: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.term(14, weight: .semibold))
                .foregroundStyle(color)
                .terminalGlow(color, radius: 2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .overlay(border)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var border: some View {
        if dashedBorder {
            Rectangle().stroke(color.opacity(0.55),
                               style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        } else {
            Rectangle().stroke(color.opacity(0.6), lineWidth: 1)
        }
    }
}

/// 상단 바용 대괄호 글리프 버튼 — `[⚙]` 처럼 대괄호 안에 SF Symbol을 넣는다.
/// `[SETTINGS]` 같은 텍스트 버튼과 같은 리듬을 유지하면서 폭을 줄이려는 것.
///
/// 유니코드 ✉/⚙(U+2709/U+2699) 대신 SF Symbol을 쓰는 이유: 그 코드포인트들은 emoji
/// presentation이 기본이라 컬러 이모지로 대체돼 터미널 톤이 깨진다. `Text(Image(systemName:))`은
/// 감싼 `.font`의 크기·weight를 따르고 baseline도 맞으므로 대괄호와 자연스럽게 붙는다.
struct TerminalGlyphButton: View {
    let systemImage: String
    var color: Color = Term.cyan
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            (Text("[") + Text(Image(systemName: systemImage)) + Text("]"))
                .font(.term(13, weight: .semibold))
                .foregroundStyle(color)
                .imageScale(.small)   // 심벌 advance가 대괄호보다 넓어 한 단계 줄여 균형을 맞춘다
                .fixedSize()          // 좁은 폭에서 마지막 ']'만 줄바꿈되는 것 방지
        }
        .buttonStyle(.plain)
    }
}

/// 모노스페이스 정렬 키:값 행 — `email    : hisnote@me.com`. 키는 고정폭으로 콜론을 맞춘다.
struct KVRow: View {
    let key: String
    let value: String
    var valueColor: Color = Term.fg
    var keyWidth: CGFloat = 84

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(key)
                .foregroundStyle(Term.cyan)
                .frame(width: keyWidth, alignment: .leading)
            Text(":").foregroundStyle(Term.dim)
            Text(value)
                .foregroundStyle(valueColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .font(.term(13))
    }
}

// MARK: - 확인 다이얼로그 (터미널 스타일 커스텀 모달)

/// 터미널 톤앤매너의 확인 다이얼로그 카드(파괴적 액션 확인용).
/// 시스템 `.confirmationDialog`/`.alert`는 색·폰트를 커스터마이즈할 수 없어 OS 기본 UI가
/// 노출되므로, 검은 배경 위 罫선 박스로 직접 그린다. `terminalConfirm(...)` 모디파이어로 띄운다.
struct TerminalDialog: View {
    let title: String
    var titleColor: Color = Term.red
    /// 대상 계정 식별용 라벨(주로 이메일). nil/빈 값이면 해당 줄을 생략한다.
    var accountLabel: String? = nil
    let message: String
    let confirmLabel: String
    var confirmColor: Color = Term.red
    let cancelLabel: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.term(15, weight: .bold))
                .foregroundStyle(titleColor)
                .terminalGlow(titleColor, radius: 2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle().fill(Term.dim.opacity(0.35)).frame(height: 1)

            if let accountLabel, !accountLabel.isEmpty {
                HStack(spacing: 6) {
                    Text("▸").foregroundStyle(Term.dim)
                    Text(accountLabel)
                        .font(.term(13, weight: .semibold))
                        .foregroundStyle(Term.cyan)
                        .lineLimit(1)
                        .truncationMode(.middle)   // 긴 이메일은 앞뒤를 남기고 가운데 생략
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }

            Text(message)
                .font(.term(12))
                .foregroundStyle(Term.dim)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                TerminalDialogButton(label: cancelLabel, color: Term.fg, action: onCancel)
                TerminalDialogButton(label: confirmLabel, color: confirmColor, action: onConfirm)
            }
            .padding(.top, 4)
        }
        .padding(18)
        .background(Term.bg)
        .overlay(Rectangle().stroke(confirmColor.opacity(0.7), lineWidth: 1.5))
        .frame(maxWidth: 320)
    }
}

/// 다이얼로그 카드 하단의 `[ 라벨 ]` 버튼. 가로를 균등 분할하도록 maxWidth를 채운다.
/// TerminalDialog(확인)와 AnnouncementOverlay(공지)가 같은 버튼을 쓴다.
struct TerminalDialogButton: View {
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.term(14, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 12)          // 폭을 글자에 맞춰 줄였을 때(fixedSize)의 좌우 여백
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .overlay(Rectangle().stroke(color.opacity(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// `terminalConfirm(isPresented:)`의 실체. scrim(반투명 배경) + 중앙 카드를 오버레이하고,
/// scrim 탭이나 [cancel]로 닫는다. 등장/소멸은 scrim 페이드 + 카드 스케일로 부드럽게.
private struct TerminalConfirmModifier: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    var accountLabel: String? = nil
    let message: String
    let confirmLabel: String
    var confirmColor: Color = Term.red
    let cancelLabel: String
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content.overlay {
            ZStack {
                if isPresented {
                    dialogScrim { isPresented = false }
                    TerminalDialog(
                        title: title, accountLabel: accountLabel, message: message,
                        confirmLabel: confirmLabel, confirmColor: confirmColor,
                        cancelLabel: cancelLabel,
                        onConfirm: { isPresented = false; onConfirm() },
                        onCancel: { isPresented = false }
                    )
                    .padding(32)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.22), value: isPresented)
        }
    }
}

/// `terminalConfirm(item:)`의 실체 — 여러 후보 중 하나(예: 계정 목록의 한 행)를 대상으로 띄운다.
/// 대상이 `item`에 담기면 표시하고, 확정/취소 시 `item`을 nil로 되돌려 닫는다.
private struct TerminalConfirmItemModifier<Item: Identifiable>: ViewModifier {
    @Binding var item: Item?
    let title: (Item) -> String
    var accountLabel: (Item) -> String? = { _ in nil }
    let message: (Item) -> String
    let confirmLabel: String
    var confirmColor: Color = Term.red
    let cancelLabel: String
    let onConfirm: (Item) -> Void

    func body(content: Content) -> some View {
        content.overlay {
            ZStack {
                if let current = item {
                    dialogScrim { item = nil }
                    TerminalDialog(
                        title: title(current), accountLabel: accountLabel(current),
                        message: message(current),
                        confirmLabel: confirmLabel, confirmColor: confirmColor,
                        cancelLabel: cancelLabel,
                        onConfirm: { onConfirm(current); item = nil },
                        onCancel: { item = nil }
                    )
                    .padding(32)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.22), value: item?.id)
        }
    }
}

/// 다이얼로그 뒤를 덮는 반투명 scrim. 탭하면 취소로 닫힌다.
/// 확인 다이얼로그와 공지 오버레이(AnnouncementOverlay)가 공유한다.
@ViewBuilder
func dialogScrim(onTap: @escaping () -> Void) -> some View {
    Color.black.opacity(0.72)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .transition(.opacity)
}

extension View {
    /// 터미널 스타일 확인 다이얼로그를 오버레이한다(단일 대상, Bool 바인딩).
    func terminalConfirm(
        isPresented: Binding<Bool>,
        title: String,
        accountLabel: String? = nil,
        message: String,
        confirmLabel: String,
        confirmColor: Color = Term.red,
        cancelLabel: String,
        onConfirm: @escaping () -> Void
    ) -> some View {
        modifier(TerminalConfirmModifier(
            isPresented: isPresented, title: title, accountLabel: accountLabel,
            message: message, confirmLabel: confirmLabel, confirmColor: confirmColor,
            cancelLabel: cancelLabel, onConfirm: onConfirm))
    }

    /// 터미널 스타일 확인 다이얼로그를 오버레이한다(후보 중 하나를 `item`으로 지정).
    func terminalConfirm<Item: Identifiable>(
        item: Binding<Item?>,
        title: @escaping (Item) -> String,
        accountLabel: @escaping (Item) -> String? = { _ in nil },
        message: @escaping (Item) -> String,
        confirmLabel: String,
        confirmColor: Color = Term.red,
        cancelLabel: String,
        onConfirm: @escaping (Item) -> Void
    ) -> some View {
        modifier(TerminalConfirmItemModifier(
            item: item, title: title, accountLabel: accountLabel, message: message,
            confirmLabel: confirmLabel, confirmColor: confirmColor,
            cancelLabel: cancelLabel, onConfirm: onConfirm))
    }
}

#Preview("확인 다이얼로그") {
    ZStack {
        // 뒤에 깔리는 화면(scrim 대비 확인용)
        VStack(spacing: 12) {
            TerminalBox(title: "ACCOUNTS") {
                KVRow(key: "email", value: "hisnote@me.com")
            }
            Spacer()
        }
        .padding(16)

        Color.black.opacity(0.72).ignoresSafeArea()

        TerminalDialog(
            title: "로그아웃하시겠어요?",
            accountLabel: "hisnote@me.com",
            message: "CLAUDE 계정의 저장된 토큰이 이 기기에서 삭제됩니다.",
            confirmLabel: "[ 로그아웃 ]",
            cancelLabel: "[ 취소 ]",
            onConfirm: {}, onCancel: {}
        )
        .padding(32)
    }
    .background(Term.bg)
}
