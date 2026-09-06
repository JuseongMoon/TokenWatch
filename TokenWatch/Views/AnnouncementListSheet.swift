//
//  AnnouncementListSheet.swift
//  TokenWatch
//
//  공지함 — 상단 바 [✉]로 여는 시트. 팝업으로 지나간 공지를 다시 읽는 곳이다.
//  - 목록은 지난 공지까지 포함한다(규칙은 AnnouncementSelector.inbox). 팝업은 "지금 띄울 1건"만
//    고르지만 여기서는 이력을 본다 — 그래서 endAt·앱 버전 범위·[다시 열지 않기]를 모두 무시한다.
//  - 읽음(seen)은 배지·굵기 표시 전용이다. 여기서 읽어도 팝업은 팝업 규칙대로 다시 뜬다.
//  - 피드 조회는 하지 않는다. scenePhase .active마다 도는 1시간 스로틀 조회에 맡긴다
//    (시트에서 조회하면 방금 읽은 공지가 시트를 닫자마자 팝업으로 다시 뜨는 흐름이 생긴다).
//

import SwiftUI

struct AnnouncementListSheet: View {
    @Environment(AnnouncementStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(appLanguageStorageKey) private var appLanguage: AppLanguage = .system

    private var loc: L10n { L10n(lang: appLanguage.resolved) }

    var body: some View {
        NavigationStack {
            ZStack {
                Term.bg.ignoresSafeArea()
                ScrollView(.vertical) {
                    VStack(spacing: 16) {
                        TerminalBox { content }
                    }
                    .padding(16)
                    // 콘텐츠 폭을 스크롤 컨테이너 폭에 고정 → 가로 스크롤 여지 제거(상하 전용)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle("ANNOUNCEMENTS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Term.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                PlainToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("[done]")
                            .font(.term(13, weight: .semibold))
                            .foregroundStyle(Term.green)
                            .fixedSize()   // 좁은 툴바 폭에서 마지막 ']'만 줄바꿈되는 것 방지
                    }
                    .buttonStyle(.plain)   // iOS 26 Liquid Glass 알약 배경 제거 → 터미널 테마 유지
                }
            }
        }
        .tint(Term.green)
        .onAppear { AnalyticsService.shared.log(.screenView(.announcements)) }
    }

    @ViewBuilder private var content: some View {
        let items = store.inbox
        if items.isEmpty {
            // 캐시가 있으면 오프라인이어도 목록이 뜨므로, "실패"는 한 번도 못 받아온 경우만이다.
            Text(store.lastFetchFailed ? loc.announcementsUnavailable : loc.announcementsEmpty)
                .font(.term(12))
                .foregroundStyle(Term.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Rectangle()
                            .fill(Term.dim.opacity(0.35))
                            .frame(height: 1)
                            .padding(.vertical, 12)
                    }
                    NavigationLink {
                        AnnouncementDetailView(announcement: item)
                    } label: {
                        AnnouncementRow(announcement: item,
                                        unread: store.isUnread(item),
                                        lang: appLanguage.resolved,
                                        loc: loc)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - 목록 행

private struct AnnouncementRow: View {
    let announcement: Announcement
    let unread: Bool
    let lang: Lang
    let loc: L10n

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(announcement.kind.chromeLabel)
                    .font(.term(12, weight: .semibold))
                    .foregroundStyle(announcement.kind.accent)
                Spacer(minLength: 8)
                Text(loc.announcementDate(announcement.publishedDate))
                    .font(.term(11))
                    .foregroundStyle(Term.dim)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if unread {
                    Text("●")
                        .font(.term(8))
                        .foregroundStyle(Term.green)
                }
                Text(title)
                    .font(.term(14, weight: unread ? .semibold : .regular))
                    .foregroundStyle(Term.fg)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())   // 여백까지 탭 영역으로
        .accessibilityElement(children: .combine)
    }

    /// 제목이 비어 있으면 본문 첫 줄로 대신한다 — 빈 행이 보이는 것보다 낫다.
    private var title: String {
        let resolved = announcement.title.resolved(for: lang)
        if !resolved.isEmpty { return resolved }
        return announcement.body.resolved(for: lang)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
    }
}

// MARK: - 상세

struct AnnouncementDetailView: View {
    let announcement: Announcement
    @Environment(AnnouncementStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(appLanguageStorageKey) private var appLanguage: AppLanguage = .system

    private var loc: L10n { L10n(lang: appLanguage.resolved) }

    var body: some View {
        let lang = appLanguage.resolved
        let title = announcement.title.resolved(for: lang)

        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                Text(loc.announcementDate(announcement.publishedDate))
                    .font(.term(11))
                    .foregroundStyle(Term.dim)

                if !title.isEmpty {
                    Text(title)
                        .font(.term(15, weight: .bold))
                        .foregroundStyle(Term.fg)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Rectangle().fill(Term.dim.opacity(0.35)).frame(height: 1)

                AnnouncementBodyText(announcement.body.resolved(for: lang))
            }
            .padding(16)
            .containerRelativeFrame(.horizontal)
        }
        .scrollContentBackground(.hidden)
        .background(Term.bg)
        .navigationTitle(announcement.kind.chromeLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Term.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationBarBackButtonHidden(true)   // 시스템 back 버튼(Liquid Glass) 대신 터미널 스타일 사용
        .toolbar {
            PlainToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Text("[back]")
                        .font(.term(13, weight: .semibold))
                        .foregroundStyle(Term.green)
                        .fixedSize()
                }
                .buttonStyle(.plain)   // iOS 26 Liquid Glass 알약 배경 제거 → 터미널 테마 유지
                .accessibilityLabel(loc.a11yBack)
            }
        }
        .onAppear {
            store.markSeen(announcement.id)
            AnalyticsService.shared.log(.announcementOpen(id: announcement.id, kind: announcement.kind))
            AnalyticsService.shared.log(.screenView(.announcementDetail))
        }
    }
}

// MARK: - Preview

#Preview("공지함") {
    let defaults = UserDefaults(suiteName: "preview.announcements.list")!
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let feed = AnnouncementFeed(items: [
        Announcement(id: "live", kind: .patch, priority: 50, publishedAt: now,
                     title: .init(ko: "1.1.0 업데이트 안내 — 공지함 추가", en: "What's new in 1.1.0"),
                     body: .init(ko: "· 공지함에서 지난 공지를 다시 볼 수 있어요.", en: nil)),
        Announcement(id: "past", kind: .notice, priority: 5,
                     publishedAt: now - 86_400_000 * 12, endAt: now - 86_400_000 * 3,
                     title: .init(ko: "서비스 점검 안내", en: "Maintenance notice"),
                     body: .init(ko: "점검이 완료되었습니다.", en: nil)),
    ])
    if let data = try? JSONEncoder().encode(feed) {
        defaults.set(data, forKey: AnnouncementStore.cachedFeedKey)
    }
    return AnnouncementListSheet()
        .environment(AnnouncementStore(defaults: defaults))
        .preferredColorScheme(.dark)
}
