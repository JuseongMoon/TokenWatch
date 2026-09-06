//
//  AnnouncementOverlay.swift
//  TokenWatch
//
//  서버 공지/패치노트 팝업. 딤 배경(scrim) 위 중앙 罫선 카드 — TerminalDialog와 같은 톤앤매너.
//  - 높이: 짧은 공지는 내용만큼, 긴 공지는 화면 세로의 절반까지 늘고 그 안에서 본문이 스크롤된다.
//    (ScrollView 단독은 제안 높이를 다 채워 짧은 공지도 반쪽 크기가 되므로 ViewThatFits로 분기.)
//    카드가 중앙 정렬이라 "위아래 대칭으로 길어지는" 요구는 자동으로 성립한다.
//  - 스크림 탭·[닫기] = 이번 실행 동안만 숨김, [다시 열지 않기] = 영구 제외. 판단은 AnnouncementStore.
//  - 표시 시점(onAppear)에만 announcement_shown을 기록한다(시트에 가려 보류된 경우는 세지 않게).
//

import SwiftUI

struct AnnouncementOverlay: View {
    let announcement: Announcement
    @Environment(AnnouncementStore.self) private var store
    @AppStorage(appLanguageStorageKey) private var appLanguage: AppLanguage = .system
    private var loc: L10n { L10n(lang: appLanguage.resolved) }

    var body: some View {
        GeometryReader { proxy in
            // 상한은 "디바이스 세로 길이의 절반" — 세이프에어리어를 더해 화면 전체 높이 기준으로 잰다.
            let screenHeight = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            ZStack {
                dialogScrim { store.close() }
                card(maxHeight: screenHeight * 0.5)
                    .padding(.horizontal, 28)
                    .frame(maxWidth: 420)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)   // GeometryReader 안에서 중앙 정렬
        }
        .accessibilityAddTraits(.isModal)
        .onAppear { AnalyticsService.shared.log(.announcementShown(id: announcement.id, kind: announcement.kind)) }
    }

    private var accent: Color {
        switch announcement.kind {
        case .notice: return Term.cyan
        case .patch:  return Term.green
        }
    }

    private var headerLabel: String {
        switch announcement.kind {
        case .notice: return "NOTICE"
        case .patch:  return "PATCH"
        }
    }

    private func card(maxHeight: CGFloat) -> some View {
        let lang = appLanguage.resolved
        let title = announcement.title.resolved(for: lang)
        let body = announcement.body.resolved(for: lang)

        return VStack(alignment: .leading, spacing: 14) {
            // 헤더: ── NOTICE ── 라벨 + 발행일
            HStack(alignment: .firstTextBaseline) {
                Text(headerLabel)
                    .font(.term(12, weight: .semibold))
                    .foregroundStyle(accent)
                    .terminalGlow(accent, radius: 2)
                Spacer(minLength: 8)
                Text(loc.announcementDate(announcement.publishedDate))
                    .font(.term(11))
                    .foregroundStyle(Term.dim)
            }

            if !title.isEmpty {
                Text(title)
                    .font(.term(15, weight: .bold))
                    .foregroundStyle(Term.fg)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Rectangle().fill(Term.dim.opacity(0.35)).frame(height: 1)

            // 본문: 짧으면 그대로, 길면 상한 안에서 스크롤. 상한은 카드 전체 frame(maxHeight:)이 쥔다.
            ViewThatFits(in: .vertical) {
                bodyText(body)
                ScrollView(.vertical, showsIndicators: true) {
                    bodyText(body)
                }
            }

            // [닫기]는 글자폭만 차지하고 나머지를 [다시 열지 않기]가 쓴다 — 균등 분할이면 영어 라벨이 두 줄로 꺾인다.
            HStack(spacing: 10) {
                TerminalDialogButton(label: "[ \(loc.announcementClose) ]", color: Term.fg) { store.close() }
                    .fixedSize(horizontal: true, vertical: false)
                TerminalDialogButton(label: "[ \(loc.announcementNever) ]", color: accent) { store.dismissForever() }
            }
            .padding(.top, 2)
        }
        .padding(18)
        // `.frame(maxHeight:)`만 두면 프레임이 제안 높이를 상한까지 "채워" 짧은 공지도 반쪽 크기가 된다
        // (실기기에서 확인). fixedSize로 nil 높이를 제안하게 하면 프레임이 내용 높이를 상한으로 자른
        // 값만 차지한다 — 짧으면 내용만큼, 길면 상한에서 멈추고 본문이 ScrollView로 넘어간다.
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(Term.bg)
        .overlay(Rectangle().stroke(accent.opacity(0.7), lineWidth: 1.5))
    }

    private func bodyText(_ body: String) -> some View {
        Text(body)
            .font(.term(13))
            .foregroundStyle(Term.fg.opacity(0.92))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

// MARK: - Preview

#Preview("짧은 공지") {
    let store = AnnouncementStore(defaults: UserDefaults(suiteName: "preview.announcements")!)
    let short = Announcement(
        id: "preview-short", kind: .patch, publishedAt: Int64(Date().timeIntervalSince1970 * 1000),
        title: .init(ko: "1.0.1 업데이트 안내", en: "What's new in 1.0.1"),
        body: .init(ko: "· 업무시간 토글을 시간대 설정과 분리했어요.\n· 토큰 갱신 중 취소로 로그인이 풀리는 문제를 고쳤어요.",
                    en: "· Work-hours toggle is now separate from the schedule.\n· Fixed a token refresh cancellation bug."))
    return ZStack {
        Term.bg.ignoresSafeArea()
        AnnouncementOverlay(announcement: short).environment(store)
    }
}

#Preview("긴 공지(절반 상한·스크롤)") {
    let store = AnnouncementStore(defaults: UserDefaults(suiteName: "preview.announcements")!)
    let paragraph = "TokenWatch는 각 서비스의 공식 사용량 API만 사용합니다. 계정 정보와 토큰은 기기 키체인에만 저장되며 개발자 서버로 전송되지 않습니다. "
    let long = Announcement(
        id: "preview-long", kind: .notice, publishedAt: Int64(Date().timeIntervalSince1970 * 1000),
        title: .init(ko: "서비스 점검 안내", en: "Maintenance notice"),
        body: .init(ko: Array(repeating: paragraph, count: 14).joined(separator: "\n\n"), en: nil))
    return ZStack {
        Term.bg.ignoresSafeArea()
        AnnouncementOverlay(announcement: long).environment(store)
    }
}
