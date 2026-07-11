//
//  AgentCardView.swift
//  TokenWatch
//
//  리스트의 한 행: 罫선 박스 하나. 타이틀 라인에 provider 태그/이름/계정,
//  본문에 사용량 게이지들. (누르면 상세로 이동 — NavigationLink는 ContentView가 감쌈)
//

import SwiftUI

struct AgentCardView: View {
    let agent: Agent
    let snapshot: AgentSnapshot?
    let isLoading: Bool
    /// 이 provider의 서비스 운영 상태. nil이면(엔드포인트 미지원 provider) 상태 줄을 감춘다
    /// — 메인 목록에는 조회 가능한 provider의 상태만 노출한다.
    var serviceHealth: ServiceHealth? = nil

    @AppStorage("tokenwatch.hideUnusedWindows") private var hideUnusedWindows = false
    @AppStorage(appLanguageStorageKey) private var appLanguage: AppLanguage = .system
    private var loc: L10n { L10n(lang: appLanguage.resolved) }

    var body: some View {
        TerminalBox(title: titleText, titleColor: agent.provider.terminalColor) {
            VStack(alignment: .leading, spacing: 12) {
                statusLine
                content
            }
        }
    }

    /// 서비스 상태 배지 한 줄(`● 정상`). 조회 가능한 provider에서만 표시.
    @ViewBuilder
    private var statusLine: some View {
        if let health = serviceHealth {
            HStack(spacing: 5) {
                Text("●")
                    .font(.term(9))
                    .foregroundStyle(Term.serviceHealthColor(health))
                Text(loc.serviceHealthLabel(health))
                    .font(.term(10))
                    .foregroundStyle(Term.dim)
                Spacer(minLength: 0)
            }
        }
    }

    /// `[C] CLAUDE · pro` 형태의 박스 타이틀.
    /// 이메일(@ 포함)은 메인 화면에 노출하지 않는다 — 플랜명 등만 덧붙인다.
    private var titleText: String {
        var t = "\(agent.provider.terminalTag) \(agent.provider.displayName.uppercased())"
        if let label = agent.accountLabel, !label.isEmpty, !label.contains("@") {
            t += " · \(label)"
        }
        return t
    }

    /// "미사용 창 숨김" 설정이 켜져 있으면 사용률 0% 게이지 창을 제외한다.
    private func visibleWindows(_ windows: [UsageWindow]) -> [UsageWindow] {
        hideUnusedWindows ? windows.filter { !$0.isUnused } : windows
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot, !snapshot.windows.isEmpty {
            let windows = visibleWindows(snapshot.windows)
            if windows.isEmpty {
                // 모든 창이 미사용(0%)이라 숨겨진 경우 — 카드가 비지 않도록 안내.
                Text(loc.usageAllUnusedHidden)
                    .font(.term(12)).foregroundStyle(Term.dim)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            } else {
                ForEach(windows) { window in
                    UsageBar(window: window)
                }
            }
            if let error = snapshot.error { errorRow(error) }   // last-good 유지 중 에러
        } else if let error = snapshot?.error {
            errorRow(error)
        } else if isLoading {
            HStack(spacing: 8) {
                TerminalSpinner(size: 13)
                Text("querying usage…")
                    .font(.term(12)).foregroundStyle(Term.dim)
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        } else {
            Text("no usage data")
                .font(.term(12)).foregroundStyle(Term.dim)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        }
    }

    private func errorRow(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("!").font(.term(13, weight: .bold)).foregroundStyle(Term.red)
            Text(error)
                .font(.term(11))
                .foregroundStyle(Term.red.opacity(0.85))
            Spacer(minLength: 0)
        }
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 14) {
            AgentCardView(
                agent: Agent(provider: .claude, accountLabel: "pro"),
                snapshot: AgentSnapshot(
                    windows: [
                        UsageWindow(label: "Current session", usedPercent: 34,
                                    resetsAt: Date().addingTimeInterval(3 * 3600),
                                    kind: .session, windowSeconds: 5 * 3600),
                        UsageWindow(label: "Current week (all models)", usedPercent: 88,
                                    resetsAt: Date().addingTimeInterval(4 * 86400),
                                    kind: .weekly, windowSeconds: 7 * 86400),
                    ],
                    planLabel: "pro", fetchedAt: Date(), error: nil),
                isLoading: false,
                serviceHealth: .operational)
            AgentCardView(
                agent: Agent(provider: .codex, accountLabel: "dev@sciencefiction.co.kr"),
                snapshot: nil, isLoading: true,
                serviceHealth: .degraded)
        }
        .padding(16)
    }
    .background(Term.bg)
}
