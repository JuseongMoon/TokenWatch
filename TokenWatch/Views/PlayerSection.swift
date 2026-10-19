//
//  PlayerSection.swift
//  TokenWatch
//
//  설정의 PLAYER 박스 — 앱 계정(TokenWatch 자체 계정) 요약만 둔다(provider 계정 박스 ACCOUNTS와 구분).
//  로그아웃: 안내 + `[ sign in ]`, 프로필 없음: `[ finish profile ]`, 로그인: 아바타·닉네임 + `[ manage ]`.
//  실제 화면(로그인·프로필 설정·계정)은 PlayerSheet가 띄운다. 데모 중에는 비활성 안내만 보인다.
//

import SwiftUI

struct PlayerSection: View {
    @Environment(AccountStore.self) private var account
    @Environment(AgentStore.self) private var store
    let loc: L10n
    let open: (PlayerSheet.Entry) -> Void

    var body: some View {
        TerminalBox(title: "PLAYER") {
            VStack(alignment: .leading, spacing: 10) {
                if store.isDemo {
                    help(loc.playerDemoDisabled)
                } else {
                    content
                }
            }
        }
        // 웹·다른 기기에서 계정을 지웠으면 캐시 프로필 대신 로그아웃 상태를 보여준다.
        .task { await account.revalidate() }
    }

    @ViewBuilder private var content: some View {
        switch account.state {
        case .unavailable:
            EmptyView()
        case .signedOut:
            help(loc.playerSignedOutHelp)
            TerminalButton(title: "[ sign in ]") { open(.login) }
        case .signingIn:
            help(loc.playerSigningIn)
        case .loading:
            help(loc.playerLoading)
        case .needsProfile:
            help(loc.playerNeedsProfile)
            TerminalButton(title: "[ finish profile ]") { open(.setup) }
        case .loadFailed:
            help(loc.playerLoadFailed)
            TerminalButton(title: "[ retry ]") { Task { await account.refreshProfile() } }
        case .deleting:
            help(loc.playerDeleting)
        case .signedIn(let profile):
            HStack(spacing: 12) {
                let avatarID = account.displayAvatarID(for: profile)
                AvatarView(avatarID: avatarID, cell: 3)
                    .accessibilityLabel(AvatarCatalog.resolve(avatarID).name(loc.lang))
                VStack(alignment: .leading, spacing: 3) {
                    NametagText(profile: profile)
                    Text(account.methods.map(loc.accountMethodName).joined(separator: " · "))
                        .font(.term(10)).foregroundStyle(Term.dim)
                }
                Spacer(minLength: 8)
                Button { open(.manage) } label: {
                    Text("[ manage ]").font(.term(12, weight: .semibold)).foregroundStyle(Term.green)
                }
                .buttonStyle(.plain)
            }
        }
        if let notice = account.notice {
            AccountNoticeLine(text: loc.accountNotice(notice), color: notice.isPositive ? Term.green : Term.red)
        }
    }

    private func help(_ text: String) -> some View {
        Text(text).font(.term(10)).foregroundStyle(Term.dim)
            .fixedSize(horizontal: false, vertical: true)
    }
}
