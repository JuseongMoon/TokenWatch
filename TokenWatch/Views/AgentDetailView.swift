//
//  AgentDetailView.swift
//  TokenWatch
//
//  상세 화면(터미널 스타일): ACCOUNT · USAGE · STATUS 罫선 박스 + [ LOGOUT ].
//  사용량은 큰 게이지 + 잔여/리셋/페이스/소진예상.
//

import SwiftUI

struct AgentDetailView: View {
    let agent: Agent

    @Environment(AgentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @AppStorage(appLanguageStorageKey) private var appLanguage: AppLanguage = .system
    private var loc: L10n { L10n(lang: appLanguage.resolved) }

    @State private var account: AccountInfo?
    @State private var showLogoutConfirm = false

    private var snapshot: AgentSnapshot? { store.snapshots[agent.id] }
    private var isLoading: Bool { store.loadingIDs.contains(agent.id) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                accountCard
                usageCard
                statusCard
                logoutButton
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .background(Term.bg)
        .navigationTitle(agent.provider.displayName.uppercased())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Term.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            PlainToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await store.refresh(agent) }
                } label: {
                    Text(isLoading ? "[··]" : "[↻]")
                        .font(.term(13, weight: .semibold))
                        .foregroundStyle(Term.cyan)
                }
                .buttonStyle(.plain)   // iOS 26 Liquid Glass 알약 배경 제거 → 터미널 테마 유지
                .disabled(isLoading)
                .accessibilityLabel(loc.a11yRefresh)
            }
        }
        .task { account = await store.accountInfo(for: agent) }
        .refreshable { await store.refresh(agent) }
        .confirmationDialog(loc.logoutConfirmTitle, isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button(loc.logout, role: .destructive) {
                store.remove(agent)
                dismiss()
            }
            Button(loc.cancel, role: .cancel) {}
        } message: {
            Text(loc.logoutMessage(provider: agent.provider.displayName))
        }
    }

    // MARK: ACCOUNT

    private var accountCard: some View {
        TerminalBox(title: "ACCOUNT", titleColor: agent.provider.terminalColor) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(agent.provider.terminalTag)
                        .foregroundStyle(agent.provider.terminalColor)
                    Text(agent.provider.displayName.uppercased())
                        .foregroundStyle(Term.fg)
                    if let plan = planText, !plan.isEmpty {
                        Text("· \(plan)").foregroundStyle(Term.dim)
                    }
                    Spacer(minLength: 0)
                }
                .font(.term(14, weight: .semibold))

                hDivider
                KVRow(key: "email", value: emailText, keyWidth: 64)
            }
        }
    }

    private var planText: String? {
        if let p = account?.plan, !p.isEmpty { return p }
        return snapshot?.planLabel
    }

    private var emailText: String {
        if let email = account?.email, !email.isEmpty { return email }
        return account == nil ? loc.checking : loc.unavailable
    }

    // MARK: USAGE

    private var usageCard: some View {
        TerminalBox(title: "USAGE") {
            VStack(alignment: .leading, spacing: 12) {
                if let snapshot, !snapshot.windows.isEmpty {
                    if isLoading { refreshingLine }
                    legend
                    ForEach(Array(snapshot.windows.enumerated()), id: \.element.id) { index, window in
                        if index > 0 { hDivider }
                        DetailUsageRow(window: window, loc: loc)
                    }
                    if let error = snapshot.error { errorRow(error) }
                } else if let error = snapshot?.error {
                    errorRow(error)
                } else if isLoading {
                    HStack(spacing: 8) {
                        TerminalSpinner(size: 13)
                        Text("loading usage…").font(.term(12)).foregroundStyle(Term.dim)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                } else {
                    Text("no usage data")
                        .font(.term(12)).foregroundStyle(Term.dim)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                }
            }
        }
    }

    private var refreshingLine: some View {
        HStack(spacing: 8) {
            TerminalSpinner(size: 11)
            Text("refreshing…").font(.term(11)).foregroundStyle(Term.dim)
            Spacer(minLength: 0)
        }
    }

    private var legend: some View {
        HStack(spacing: 6) {
            // 실제 게이지 마커와 동일한 일자 세로선.
            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: 12)
                .overlay(Rectangle().stroke(Color.black.opacity(0.45), lineWidth: 0.5))
            Text(loc.usageLegend)
                .font(.term(10)).foregroundStyle(Term.dim)
            Spacer(minLength: 0)
        }
    }

    // MARK: STATUS

    private var statusCard: some View {
        TerminalBox(title: "STATUS") {
            VStack(alignment: .leading, spacing: 10) {
                if let snapshot {
                    KVRow(key: "updated", value: relativeString(snapshot.fetchedAt), keyWidth: 96)
                }
                KVRow(key: "provider", value: agent.provider.displayName, keyWidth: 96)
                if let account, !account.canRefresh, let exp = account.expiresAt {
                    KVRow(key: "re-login", value: absoluteString(exp),
                          valueColor: Term.yellow, keyWidth: 96)
                }
            }
        }
    }

    // MARK: LOGOUT

    private var logoutButton: some View {
        TerminalButton(title: "[ LOGOUT ]", color: Term.red) {
            showLogoutConfirm = true
        }
    }

    // MARK: 재사용 조각

    private var hDivider: some View {
        Rectangle().fill(Term.dim.opacity(0.35)).frame(height: 1).padding(.vertical, 2)
    }

    private func errorRow(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("!").font(.term(13, weight: .bold)).foregroundStyle(Term.red)
            Text(error).font(.term(11)).foregroundStyle(Term.red.opacity(0.85))
            Spacer(minLength: 0)
        }
    }

    private func relativeString(_ date: Date) -> String {
        loc.relativeTime(date)
    }

    private func absoluteString(_ date: Date) -> String {
        loc.absoluteDateTime(date)
    }
}

// MARK: - 사용량 상세 한 줄

/// 상세 화면의 창 1개: 라벨 + 큰 게이지 + 잔여/리셋/페이스/소진예상.
private struct DetailUsageRow: View {
    let window: UsageWindow
    let loc: L10n

    private var usedFraction: Double { max(0, min(1, window.usedPercent / 100)) }
    private var statusColor: Color { Term.statusColor(remainingPercent: window.remainingPercent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(window.label.uppercased())
                    .font(.term(12, weight: .semibold)).foregroundStyle(Term.cyan)
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))% used")
                    .font(.term(12)).foregroundStyle(statusColor)
            }

            // 마커/페이스/남은시간은 시간에 따라 변하므로 TimelineView로 갱신.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let now = context.date
                VStack(alignment: .leading, spacing: 8) {
                    TerminalGauge(usedFraction: usedFraction, fillColor: statusColor,
                                  elapsedFraction: window.elapsedFraction(at: now),
                                  height: 20, bracketSize: 15)

                    KVRow(key: "remaining",
                          value: "\(Int(window.remainingPercent.rounded()))%",
                          valueColor: statusColor, keyWidth: 84)
                    if let reset = resetText(now: now) {
                        KVRow(key: "reset", value: reset, keyWidth: 84)
                    }
                    if let pace = paceInfo(now: now) {
                        Text(pace.text).font(.term(11)).foregroundStyle(pace.color)
                    }
                    if let warn = depletionWarning(now: now) {
                        Text("!! " + warn).font(.term(11)).foregroundStyle(Term.red)
                    }
                }
            }
        }
    }

    private func resetText(now: Date) -> String? {
        guard let exact = window.resetExactText(loc) else { return nil }
        if let remain = window.resetRemainingText(loc, at: now) {
            return "\(exact) · \(remain)"
        }
        return exact
    }

    /// 사용률 vs 시간경과율 페이스 안내 — 화살표 텍스트로.
    private func paceInfo(now: Date) -> (text: String, color: Color)? {
        guard let delta = window.paceDelta(at: now) else { return nil }
        let mag = Int(abs(delta).rounded())
        if delta >= 3 {
            return (loc.paceAhead(mag), Term.yellow)
        } else if delta <= -3 {
            return (loc.paceUnder(mag), Term.green)
        } else {
            return (loc.paceEven, Term.dim)
        }
    }

    /// 현재 속도 유지 시 리셋 전 소진되는 경우에만 경고 문자열.
    private func depletionWarning(now: Date) -> String? {
        guard let elapsed = window.elapsedFraction(at: now),
              let resetsAt = window.resetsAt,
              let total = window.windowSeconds,
              window.usedPercent > 1, window.usedPercent < 99.5,
              elapsed > 0.02 else { return nil }
        let elapsedSec = total * elapsed
        guard elapsedSec > 0 else { return nil }
        let ratePerSec = window.usedPercent / elapsedSec
        guard ratePerSec > 0 else { return nil }
        let secsTo100 = (100 - window.usedPercent) / ratePerSec
        let projectedFull = now.addingTimeInterval(secsTo100)
        guard projectedFull < resetsAt else { return nil }
        let c = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: projectedFull)
        let d = max(0, c.day ?? 0), h = max(0, c.hour ?? 0), m = max(0, c.minute ?? 0)
        let when = loc.depletionETA(days: d, hours: h, minutes: m)
        return loc.depletionWarning(when)
    }
}

#Preview("상세 사용량 행") {
    VStack(alignment: .leading, spacing: 14) {
        DetailUsageRow(window: UsageWindow(label: "Current session", usedPercent: 70,
                                           resetsAt: Date().addingTimeInterval(3 * 3600),
                                           kind: .session, windowSeconds: 5 * 3600),
                       loc: L10n(lang: .en))
        DetailUsageRow(window: UsageWindow(label: "Current week (all models)", usedPercent: 12,
                                           resetsAt: Date().addingTimeInterval(2 * 86400),
                                           kind: .weekly, windowSeconds: 7 * 86400),
                       loc: L10n(lang: .en))
    }
    .padding()
    .background(Term.bg)
}
