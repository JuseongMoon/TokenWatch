//
//  PlayerSheet.swift
//  TokenWatch
//
//  앱 계정 시트. 상태에 따라 세 화면 중 하나를 보여준다 — 로그인(account_login) · 프로필 설정(profile_setup) ·
//  계정(account). 화면 이벤트는 각 화면이 나타날 때 1회씩 기록한다(Android와 같은 단위).
//  로그인·가입으로 들어왔으면 프로필이 생기는 순간 닫고, 계정 화면에서 로그아웃·삭제하면 닫는다.
//

import AuthenticationServices
import SwiftUI

struct PlayerSheet: View {
    enum Entry: String, Identifiable {
        case login, setup, manage
        var id: String { rawValue }
    }

    let entry: Entry
    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    @AppStorage(appLanguageStorageKey) private var appLanguage: AppLanguage = .system

    private var loc: L10n { L10n(lang: appLanguage.resolved) }

    var body: some View {
        NavigationStack {
            ZStack {
                Term.bg.ignoresSafeArea()
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 16) {
                        screen
                    }
                    .padding(16)
                    .containerRelativeFrame(.horizontal)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("PLAYER")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Term.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                PlainToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text("[done]")
                            .font(.term(13, weight: .semibold))
                            .foregroundStyle(Term.green)
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .tint(Term.green)
        .onChange(of: account.state) { _, state in
            switch state {
            case .signedIn where entry != .manage: dismiss()
            case .signedOut where entry != .login: dismiss()
            default: break
            }
        }
        .onDisappear { account.notice = nil }
    }

    @ViewBuilder private var screen: some View {
        switch account.state {
        case .unavailable:
            EmptyView()
        case .signedOut, .signingIn, .loadFailed:
            AccountLoginView(loc: loc)
        case .loading:
            statusLine(loc.playerLoading)
        case .needsProfile:
            ProfileSetupView(loc: loc)
        case .signedIn(let profile):
            AccountView(profile: profile, loc: loc)
        case .deleting:
            statusLine(loc.playerDeleting)
        }
    }

    private func statusLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            TerminalSpinner(color: Term.cyan, size: 12)
            Text(text).font(.term(12)).foregroundStyle(Term.dim)
        }
    }
}

// MARK: - 로그인

private struct AccountLoginView: View {
    @Environment(AccountStore.self) private var account
    let loc: L10n

    var body: some View {
        TerminalBox(title: "SIGN IN") {
            VStack(alignment: .leading, spacing: 14) {
                Text(loc.accountLoginIntro)
                    .font(.term(11)).foregroundStyle(Term.dim)
                    .fixedSize(horizontal: false, vertical: true)
                AccountBrandButtons(
                    showApple: true,
                    showGoogle: account.isGoogleAvailable,
                    disabled: account.state != .signedOut && account.state != .loadFailed,
                    onApple: { Task { await account.signIn(with: .apple) } },
                    onGoogle: { Task { await account.signIn(with: .google) } })
                #if DEBUG
                if !account.isGoogleAvailable {
                    Text(loc.accountGoogleNotConfigured).font(.term(10)).foregroundStyle(Term.yellow)
                }
                #endif
                if case .signingIn = account.state {
                    HStack(spacing: 8) {
                        TerminalSpinner(color: Term.cyan, size: 12)
                        Text(loc.playerSigningIn).font(.term(11)).foregroundStyle(Term.dim)
                    }
                }
                if let notice = account.notice {
                    AccountNoticeLine(text: loc.accountNotice(notice))
                }
            }
        }
        .onAppear { AnalyticsService.shared.log(.screenView(.accountLogin)) }
    }
}

// MARK: - 프로필 설정(첫 로그인)

private struct ProfileSetupView: View {
    @Environment(AccountStore.self) private var account
    let loc: L10n

    @State private var nickname = ""
    @State private var avatarID = AvatarCatalog.random().id
    @State private var termsAccepted = false
    @State private var error: NicknameError?
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TerminalBox(title: "PROFILE") {
                VStack(alignment: .leading, spacing: 14) {
                    Text(loc.profileSetupIntro)
                        .font(.term(11)).foregroundStyle(Term.dim)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("nickname").font(.term(11, weight: .semibold)).foregroundStyle(Term.cyan)
                        NicknameField(text: $nickname, placeholder: loc.nicknamePlaceholder)
                            .onChange(of: nickname) { _, _ in error = nil }
                        Text(loc.nicknameRule).font(.term(10)).foregroundStyle(Term.dim)
                        if let error, error != .termsRequired {
                            AccountNoticeLine(text: loc.nicknameError(error))
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("avatar").font(.term(11, weight: .semibold)).foregroundStyle(Term.cyan)
                        AvatarPicker(selection: $avatarID, lang: loc.lang)
                    }

                    termsRow

                    TerminalButton(title: account.isWorking ? "[ saving… ]" : "[ save ]") {
                        Task { await save() }
                    }
                    .disabled(account.isWorking)

                    if let notice = account.notice {
                        AccountNoticeLine(text: loc.accountNotice(notice))
                    }
                }
            }

            // 로그인만 하고 가입을 그만두는 길 — Auth 기록까지 지울 수 있어야 한다(계정 삭제 요건).
            VStack(alignment: .leading, spacing: 8) {
                Text(loc.profileSetupQuit).font(.term(10)).foregroundStyle(Term.dim)
                HStack(spacing: 16) {
                    Button { account.signOut() } label: {
                        Text("[ sign out ]").font(.term(12)).foregroundStyle(Term.cyan)
                    }
                    .buttonStyle(.plain)
                    Button { confirmDelete = true } label: {
                        Text("[ delete account ]").font(.term(12)).foregroundStyle(Term.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            .disabled(account.isWorking)
        }
        .onAppear { AnalyticsService.shared.log(.screenView(.profileSetup)) }
        .terminalConfirm(
            isPresented: $confirmDelete,
            title: loc.accountDeleteTitle,
            message: loc.accountDeleteMessage,
            confirmLabel: "[ \(loc.accountDelete) ]",
            cancelLabel: "[ \(loc.cancel) ]",
            onConfirm: { Task { await account.deleteAccount() } })
    }

    private var termsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                termsAccepted.toggle()
                if termsAccepted, error == .termsRequired { error = nil }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(termsAccepted ? "[x]" : "[ ]")
                        .foregroundStyle(termsAccepted ? Term.green : Term.dim)
                    Text(loc.termsAgree).foregroundStyle(Term.fg)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.term(12))
            }
            .buttonStyle(.plain)
            HStack(spacing: 16) {
                linkButton(loc.termsLink, AccountLinks.terms)
                linkButton(loc.privacyLink, AccountLinks.privacy)
            }
            .padding(.leading, 30)
            Text(loc.termsMonsterNote)
                .font(.term(10)).foregroundStyle(Term.dim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 30)
            if error == .termsRequired {
                AccountNoticeLine(text: loc.nicknameError(.termsRequired))
            }
        }
    }

    private func linkButton(_ title: String, _ url: URL) -> some View {
        Button { InAppSafari.open(url) } label: {
            Text(title).font(.term(11)).foregroundStyle(Term.cyan)
        }
        .buttonStyle(.plain)
    }

    private func save() async {
        account.notice = nil
        switch await account.createProfile(nickname: nickname, avatarID: avatarID, termsAccepted: termsAccepted) {
        case .saved, .failed: error = nil
        case .invalid(let e): error = e
        }
    }
}

// MARK: - 계정

private struct AccountView: View {
    @Environment(AccountStore.self) private var account
    let profile: PlayerProfile
    let loc: L10n

    @State private var nickname = ""
    @State private var nicknameError: NicknameError?
    @State private var avatarID = ""
    @State private var confirmSignOut = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TerminalBox(title: "PROFILE") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        let shownAvatar = account.displayAvatarID(for: profile)
                        AvatarView(avatarID: shownAvatar, cell: 4)
                            .accessibilityLabel(AvatarCatalog.resolve(shownAvatar).name(loc.lang))
                        VStack(alignment: .leading, spacing: 4) {
                            NametagText(profile: profile, size: 16)
                            Text(account.methods.map(loc.accountMethodName).joined(separator: " · "))
                                .font(.term(10)).foregroundStyle(Term.dim)
                        }
                        Spacer(minLength: 0)
                    }
                    if let notice = account.notice {
                        AccountNoticeLine(text: loc.accountNotice(notice),
                                          color: notice.isPositive ? Term.green : Term.red)
                    }
                }
            }

            BestiaryBox(loc: loc)
            nicknameBox
            avatarBox
            linkBox

            TerminalBox(title: "SESSION") {
                HStack(spacing: 16) {
                    Button { confirmSignOut = true } label: {
                        Text("[ sign out ]").font(.term(13)).foregroundStyle(Term.cyan)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button { confirmDelete = true } label: {
                        Text("[ delete account ]").font(.term(13)).foregroundStyle(Term.red)
                    }
                    .buttonStyle(.plain)
                }
                .disabled(account.isWorking)
            }
        }
        .onAppear {
            nickname = profile.nickname
            avatarID = profile.avatarID
            AnalyticsService.shared.log(.screenView(.account))
        }
        .terminalConfirm(
            isPresented: $confirmSignOut,
            title: loc.accountSignOutTitle,
            accountLabel: profile.nametag,
            message: loc.accountSignOutMessage,
            confirmLabel: "[ \(loc.accountSignOut) ]",
            cancelLabel: "[ \(loc.cancel) ]",
            onConfirm: { account.signOut() })
        .terminalConfirm(
            isPresented: $confirmDelete,
            title: loc.accountDeleteTitle,
            accountLabel: profile.nametag,
            message: loc.accountDeleteMessage,
            confirmLabel: "[ \(loc.accountDelete) ]",
            cancelLabel: "[ \(loc.cancel) ]",
            onConfirm: { Task { await account.deleteAccount() } })
    }

    private var cooldown: (days: Int, hours: Int)? {
        let ms = account.nicknameCooldownRemainingMs
        guard ms > 0 else { return nil }
        let hours = Int((ms + 3_599_999) / 3_600_000)   // 올림 — "0시간 남음"을 보이지 않게
        return (hours / 24, hours % 24)
    }

    private var nicknameBox: some View {
        TerminalBox(title: "NICKNAME") {
            VStack(alignment: .leading, spacing: 8) {
                NicknameField(text: $nickname, placeholder: loc.nicknamePlaceholder)
                    .onChange(of: nickname) { _, _ in nicknameError = nil }
                    .disabled(cooldown != nil)
                if let cooldown {
                    Text("\(loc.nicknameError(.cooldown)) \(loc.nicknameCooldownRemaining(days: cooldown.days, hours: cooldown.hours))")
                        .font(.term(10)).foregroundStyle(Term.yellow)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(loc.nicknameRule).font(.term(10)).foregroundStyle(Term.dim)
                    Text(loc.nicknameTagHint).font(.term(10)).foregroundStyle(Term.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    if NicknamePolicy.normalize(nickname) != profile.nickname {
                        TerminalButton(title: account.isWorking ? "[ saving… ]" : "[ save nickname ]") {
                            Task {
                                account.notice = nil
                                if case .invalid(let e) = await account.changeNickname(nickname) { nicknameError = e }
                            }
                        }
                        .disabled(account.isWorking)
                    }
                }
                if let nicknameError {
                    AccountNoticeLine(text: loc.nicknameError(nicknameError))
                }
            }
        }
    }

    private var avatarBox: some View {
        TerminalBox(title: "AVATAR") {
            VStack(alignment: .leading, spacing: 10) {
                if account.isOperator, AvatarCatalog.operatorAvatar != nil {
                    Text(loc.operatorAvatarNote).font(.term(10)).foregroundStyle(Term.yellow)
                        .fixedSize(horizontal: false, vertical: true)
                }
                AvatarPicker(selection: $avatarID, lang: loc.lang)
                if avatarID != profile.avatarID, !avatarID.isEmpty {
                    TerminalButton(title: account.isWorking ? "[ saving… ]" : "[ save avatar ]") {
                        Task {
                            account.notice = nil
                            _ = await account.changeAvatar(avatarID)
                        }
                    }
                    .disabled(account.isWorking)
                } else {
                    Text(loc.accountAvatarHelp).font(.term(10)).foregroundStyle(Term.dim)
                }
            }
        }
    }

    @ViewBuilder private var linkBox: some View {
        let missing = AccountMethod.allCases.filter {
            !account.methods.contains($0) && ($0 != .google || account.isGoogleAvailable)
        }
        if !missing.isEmpty {
            TerminalBox(title: "LINK") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(loc.accountLinkHelp).font(.term(10)).foregroundStyle(Term.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    AccountBrandButtons(
                        appleType: .continue,
                        showApple: missing.contains(.apple),
                        showGoogle: missing.contains(.google),
                        disabled: account.isWorking,
                        onApple: { Task { account.notice = nil; await account.link(.apple) } },
                        onGoogle: { Task { account.notice = nil; await account.link(.google) } })
                }
            }
        }
    }
}

/// 약관·개인정보 링크(인앱 Safari로 연다).
enum AccountLinks {
    static let terms = URL(string: "https://sciencefiction.co.kr/tokenwatch/terms/")!
    static let privacy = URL(string: "https://sciencefiction.co.kr/tokenwatch/privacy/")!
}
