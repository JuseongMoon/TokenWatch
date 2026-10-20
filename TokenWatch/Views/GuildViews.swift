//
//  GuildViews.swift
//  TokenWatch
//
//  모험가 길드(V2) 화면: 상단 바 간판 버튼(공지 버튼 왼쪽), 리더보드 시트(상위 100·내 순위·신고·차단), 몬스터 사냥 동의 시트.
//  - 간판: 누르면 순위, 동의 전이면 동의 화면(청록 점 표시).
//  - 리더보드: 공개 목록(로그인 전에도 볼 수 있음). 신고는 로그인한 계정만, 차단은 기기 로컬 숨김.
//  - 동의: 무엇을 서버로 보내는지(사용률·계정 정보는 안 보냄)와 공개 범위를 보여 주고 약관 v2 동의를 받는다.
//

import SwiftUI

extension PixelSprite {
    /// 길드 게시판 — 나무 판에 양피지 공고(16×12, 정지 프레임).
    static let guildSign: PixelSprite = {
        let legend: [Character: Int] = ["B": 1, "b": 2, "h": 3, "p": 4, "P": 5, "k": 6]
        let rows = [
            ".BBBBBBBBBBBBBB.",
            "BhhbbbbbbbbbbbbB",
            "BbppppppppppppbB",
            "BbpkkpkkkpkkPpbB",
            "BbppppppppppppbB",
            "BbpkkkpkkpkkPpbB",
            "BbPPPPPPPPPPPPbB",
            "BbbbbbbbbbbbbbbB",
            ".BBBBBBBBBBBBBB.",
            "...Bb......Bb...",
            "...Bb......Bb...",
            "...BB......BB...",
        ]
        let frame = rows.map { $0.map { legend[$0] ?? 0 } }
        return PixelSprite(frames: [frame], palette: [
            1: Color(red: 0.43, green: 0.26, blue: 0.13),   // #6E4220 나무 외곽
            2: Color(red: 0.66, green: 0.42, blue: 0.20),   // #A86A32 나무
            3: Color(red: 0.85, green: 0.60, blue: 0.37),   // #D99A5E 나무 반사광
            4: Color(red: 0.94, green: 0.89, blue: 0.71),   // #F0E2B6 양피지
            5: Color(red: 0.79, green: 0.73, blue: 0.54),   // #C9B98A 양피지 그늘
            6: Color(red: 0.23, green: 0.16, blue: 0.10),   // #3A2A1A 잉크
        ])
    }()
}

// MARK: - 상단 바 간판 버튼

/// 상단 바(공지 버튼 왼쪽)의 길드 간판. 누르면 순위, 몬스터 동의 전이면 동의 화면을 연다.
/// 동의가 필요하면 우상단에 청록 점을 얹는다. 데모 중에는 흐리게 막는다.
struct GuildSignButton: View {
    @Environment(MonsterStore.self) private var monsters
    @Environment(AgentStore.self) private var store
    let loc: L10n
    let onOpenRanks: () -> Void
    let onOpenConsent: () -> Void

    /// 픽셀 한 칸 — 3배 화면에서 정수 픽셀(4px)이 되는 4/3pt(간판 21×16pt).
    static let cell: CGFloat = 4.0 / 3.0

    var body: some View {
        Button {
            if monsters.needsConsent { onOpenConsent() } else { onOpenRanks() }
        } label: {
            PixelSpriteView(sprite: .guildSign, frameIndex: 0, cell: Self.cell,
                            flatColor: store.isDemo ? Term.dim : nil)
                .overlay(alignment: .topTrailing) {
                    if monsters.needsConsent, !store.isDemo {
                        Circle().fill(Term.cyan).frame(width: 6, height: 6).offset(x: 3, y: -3)
                    }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isDemo)
        .accessibilityLabel(loc.guildBoardTitle)
        .accessibilityHint(monsters.needsConsent ? loc.guildBoardConsent : "")
    }
}

// MARK: - 리더보드

struct LeaderboardSheet: View {
    @Environment(MonsterStore.self) private var monsters
    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    @AppStorage(appLanguageStorageKey) private var appLanguage: AppLanguage = .system
    private var loc: L10n { L10n(lang: appLanguage.resolved) }

    /// 로그인 화면으로 — 호출측이 이 시트를 닫은 뒤 PLAYER 로그인 시트를 연다.
    let onSignIn: () -> Void

    @State private var showingConsent = false
    @State private var menuTarget: LeaderboardEntry?
    @State private var reportTarget: LeaderboardEntry?
    @State private var notice: (text: String, ok: Bool)?

    var body: some View {
        NavigationStack {
            ZStack {
                Term.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(loc.leaderboardIntro)
                            .font(.term(11)).foregroundStyle(Term.dim)
                            .fixedSize(horizontal: false, vertical: true)
                        mine
                        if let notice {
                            AccountNoticeLine(text: notice.text, color: notice.ok ? Term.green : Term.red)
                        }
                        ranks
                        if !monsters.blockedUIDs.isEmpty {
                            Text(loc.leaderboardBlockedNote).font(.term(10)).foregroundStyle(Term.dim)
                        }
                    }
                    .padding(16)
                    .containerRelativeFrame(.horizontal)
                }
                .refreshable { await monsters.refreshGuild(force: true) }
            }
            .navigationTitle("GUILD")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Term.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                PlainToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text("[done]").font(.term(13, weight: .semibold)).foregroundStyle(Term.green).fixedSize()
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay { menuOverlay }
            .sheet(isPresented: $showingConsent) { MonsterConsentSheet().environment(monsters) }
        }
        .tint(Term.green)
        .task { await monsters.refreshGuild() }
        .onAppear { AnalyticsService.shared.log(.screenView(.leaderboard)) }
    }

    // 내 영역
    @ViewBuilder private var mine: some View {
        TerminalBox(title: "ME") {
            if let owner = monsters.activeOwner, let profile = account.profile {
                HStack(spacing: 10) {
                    AvatarView(avatarID: account.displayAvatarID(for: profile), cell: 2)
                    VStack(alignment: .leading, spacing: 3) {
                        NametagText(profile: profile, size: 13)
                        let stats = monsters.rank?.stats ?? monsters.stats ?? MonsterStatsDTO()
                        Text(loc.leaderboardMine(common: stats.commonKills, special: stats.specialKills))
                            .font(.term(10)).foregroundStyle(Term.dim)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        if let rank = monsters.rank, rank.listed {
                            Text(rank.rank.map { "#\($0)" } ?? "—")
                                .font(.term(15, weight: .bold)).foregroundStyle(Term.yellow)
                            Text("\(rank.stats.totalScore) pts").font(.term(11)).foregroundStyle(Term.green)
                        } else {
                            Text(loc.leaderboardNotListed).font(.term(10)).foregroundStyle(Term.dim)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .id(owner)
            } else if monsters.needsConsent {
                Text(loc.guildBoardConsent).font(.term(11)).foregroundStyle(Term.cyan)
                TerminalButton(title: "[ start ]") { showingConsent = true }
            } else {
                Text(loc.leaderboardGuestHint)
                    .font(.term(11)).foregroundStyle(Term.dim)
                    .fixedSize(horizontal: false, vertical: true)
                if monsters.guestKillCount > 0 {
                    Text(loc.guildBoardGuestKills(monsters.guestKillCount))
                        .font(.term(11)).foregroundStyle(Term.green)
                }
                if account.isAvailable, account.uid == nil {
                    TerminalButton(title: "[ sign in ]") { onSignIn() }
                }
            }
        }
    }

    // 순위 목록
    @ViewBuilder private var ranks: some View {
        TerminalBox(title: "TOP 100") {
            let list = monsters.visibleLeaderboard
            if list.isEmpty {
                Text(monsters.leaderboardFailed ? loc.leaderboardFailed
                     : (monsters.leaderboardLoadedAt == nil ? loc.leaderboardLoading : loc.leaderboardEmpty))
                    .font(.term(11)).foregroundStyle(Term.dim)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, entry in
                        row(entry, rank: index + 1)
                    }
                }
            }
        }
    }

    private func row(_ entry: LeaderboardEntry, rank: Int) -> some View {
        let isMe = entry.uid == account.uid
        return HStack(spacing: 10) {
            Text(String(format: "%3d", rank))
                .font(.term(12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(rank <= 3 ? Term.yellow : Term.dim)
            AvatarView(avatarID: entry.avatarID, cell: 2)
            (Text(entry.nickname).foregroundStyle(isMe ? Term.green : Term.fg)
             + Text(" #\(entry.tag)").foregroundStyle(Term.dim))
                .font(.term(12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 6)
            Text("\(entry.totalScore)").font(.term(12)).monospacedDigit().foregroundStyle(Term.green)
            if !isMe {
                Button { menuTarget = entry } label: {
                    Text("[⋯]").font(.term(12)).foregroundStyle(Term.dim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc.reportTitle("\(entry.nickname) #\(entry.tag)"))
            }
        }
        .frame(minHeight: 36)
    }

    // 신고·차단 선택(터미널 다이얼로그)
    @ViewBuilder private var menuOverlay: some View {
        if let entry = menuTarget {
            ZStack {
                dialogScrim { menuTarget = nil }
                TerminalBox(title: "\(entry.nickname) #\(entry.tag)", borderColor: Term.cyan) {
                    VStack(alignment: .leading, spacing: 10) {
                        if reportTarget == nil {
                            TerminalButton(title: "[ report ]", color: Term.yellow) { reportTarget = entry }
                            TerminalButton(title: "[ block ]", color: Term.red) {
                                monsters.block(uid: entry.uid)
                                menuTarget = nil
                            }
                            Text(loc.blockMessage).font(.term(10)).foregroundStyle(Term.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(loc.reportIntro).font(.term(11)).foregroundStyle(Term.dim)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(MonsterAPIClient.ReportReason.allCases, id: \.self) { reason in
                                TerminalButton(title: loc.reportReason(reason), color: Term.yellow) {
                                    Task { await send(reason, about: entry) }
                                }
                            }
                        }
                        TerminalButton(title: "[ cancel ]", color: Term.dim) {
                            reportTarget = nil
                            menuTarget = nil
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    private func send(_ reason: MonsterAPIClient.ReportReason, about entry: LeaderboardEntry) async {
        reportTarget = nil
        menuTarget = nil
        guard account.uid != nil else {
            notice = (loc.reportNeedsAccount, false)
            return
        }
        let ok = await monsters.report(uid: entry.uid, reason: reason)
        notice = ok ? (loc.reportSent, true) : (loc.reportFailed, false)
    }
}

// MARK: - 동의

struct MonsterConsentSheet: View {
    @Environment(MonsterStore.self) private var monsters
    @Environment(\.dismiss) private var dismiss
    @AppStorage(appLanguageStorageKey) private var appLanguage: AppLanguage = .system
    private var loc: L10n { L10n(lang: appLanguage.resolved) }

    @State private var agreed = false
    @State private var working = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ZStack {
                Term.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        TerminalBox(title: loc.consentTitle) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(loc.consentIntro).font(.term(11)).foregroundStyle(Term.fg)
                                    .fixedSize(horizontal: false, vertical: true)
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(loc.consentSent, id: \.self) { line in
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            Text("▸").foregroundStyle(Term.cyan)
                                            Text(line).foregroundStyle(Term.fg)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        .font(.term(11))
                                    }
                                }
                                Text(loc.consentNotSent).font(.term(11)).foregroundStyle(Term.yellow)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        agreeRow
                        TerminalButton(title: working ? "[ … ]" : "[ agree & start ]",
                                       color: agreed ? Term.green : Term.dim) {
                            Task { await accept() }
                        }
                        .disabled(!agreed || working)
                        if failed { AccountNoticeLine(text: loc.consentFailed) }
                        Text(loc.consentLater).font(.term(10)).foregroundStyle(Term.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle("MONSTERS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Term.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                PlainToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Text("[later]").font(.term(13, weight: .semibold)).foregroundStyle(Term.dim).fixedSize()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .tint(Term.green)
        .onAppear { AnalyticsService.shared.log(.screenView(.monsterConsent)) }
    }

    private var agreeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { agreed.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(agreed ? "[x]" : "[ ]").foregroundStyle(agreed ? Term.green : Term.dim)
                    Text(loc.consentAgree).foregroundStyle(Term.fg)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.term(12))
            }
            .buttonStyle(.plain)
            HStack(spacing: 16) {
                link(loc.termsLink, AccountLinks.terms)
                link(loc.privacyLink, AccountLinks.privacy)
            }
            .padding(.leading, 30)
        }
    }

    private func link(_ title: String, _ url: URL) -> some View {
        Button { InAppSafari.open(url) } label: {
            Text(title).font(.term(11)).foregroundStyle(Term.cyan)
        }
        .buttonStyle(.plain)
    }

    private func accept() async {
        working = true
        failed = false
        let ok = await monsters.acceptConsent()
        working = false
        if ok { dismiss() } else { failed = true }
    }
}
