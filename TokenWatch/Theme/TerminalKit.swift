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
