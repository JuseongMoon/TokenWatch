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
        TerminalBox {
            VStack(alignment: .leading, spacing: 12) {
                titleBar
                content
            }
        }
    }

    /// 카드 헤더: `[C] CLAUDE [●] · pro`. 서비스 이름 오른쪽에 서비스 운영 상태를
    /// 속이 찬 원으로 표시하고, 그 색으로 정상/장애/점검을 나타낸다(조회 가능한 provider만).
    private var titleBar: some View {
        HStack(spacing: 6) {
            Text("\(agent.provider.terminalTag) \(agent.provider.displayName.uppercased())")
                .foregroundStyle(agent.provider.terminalColor)
                .terminalGlow(agent.provider.terminalColor, radius: 2)
                .lineLimit(1)
            statusCircle
            if let plan = planSuffix {
                Text("· \(plan)")
                    .foregroundStyle(agent.provider.terminalColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.term(12, weight: .semibold))
    }

    /// 서비스 이름 오른쪽의 상태 배지 `[●]`. 속이 찬 원을 상태색으로, 대괄호는 흐리게.
    /// 원은 텍스트 글리프 대신 Circle 도형으로 그려(대괄호 텍스트와) 상하 중앙정렬을 맞추고
    /// 크기를 정확히 제어한다. 엔드포인트가 없는 provider(serviceHealth == nil)와 판정 불가
    /// (unknown)에는 표시하지 않는다 — 메인 목록엔 확정된 상태만 노출한다.
    @ViewBuilder
    private var statusCircle: some View {
        if let health = serviceHealth, health != .unknown {
            statusBadge(health)
        }
    }

    /// 상태 배지 `[●]`(대괄호는 흐리게). 실제/테스트 공통 렌더.
    private func statusBadge(_ health: ServiceHealth) -> some View {
        HStack(spacing: 1.5) {
            Text("[").foregroundStyle(Term.dim)
            statusGlyph(health)
            Text("]").foregroundStyle(Term.dim)
        }
        .accessibilityElement()
        .accessibilityLabel(loc.serviceHealthLabel(health))
    }

    /// 상태별 배지 글리프: 이상만 점멸, 전체점검은 "점검중" 텍스트, 그 외(정상·주의·전체이상)는 정적 점.
    @ViewBuilder
    private func statusGlyph(_ health: ServiceHealth) -> some View {
        switch health {
        case .maintenance:
            Text(loc.serviceMaintenanceBadge)
                .font(.term(10, weight: .semibold))
                .foregroundStyle(Term.orange)
        case .major:
            TerminalBlink { statusDot(health) }
        default:
            statusDot(health)
        }
    }

    private func statusDot(_ health: ServiceHealth) -> some View {
        Circle()
            .fill(Term.serviceHealthDotColor(health))
            .frame(width: 8, height: 8)
    }

    /// 타이틀에 덧붙일 플랜명 등(있을 때). 이메일(@ 포함)은 메인 화면에 노출하지 않는다.
    private var planSuffix: String? {
        guard let label = agent.accountLabel, !label.isEmpty, !label.contains("@") else { return nil }
        return label
    }

    /// "미사용 창 숨김" 설정이 켜져 있으면 사용률 0% 게이지 창을 제외한다.
    private func visibleWindows(_ windows: [UsageWindow]) -> [UsageWindow] {
        hideUnusedWindows ? windows.filter { !$0.isUnused } : windows
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot, !snapshot.windows.isEmpty {
            let windows = visibleWindows(snapshot.windows)
            // 에러(429 등)는 이름과 그래프 사이에 표시하고, 그래프는 지우지 않고 그대로 유지한다.
            if let error = snapshot.error { errorRow(error) }
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
                serviceHealth: .caution)
            AgentCardView(
                agent: Agent(provider: .stability),
                snapshot: nil, isLoading: false,
                serviceHealth: .totalOutage)
            AgentCardView(
                agent: Agent(provider: .fal),
                snapshot: nil, isLoading: false,
                serviceHealth: .maintenance)
            // 429 백오프: 캐시 그래프는 유지하고 이름과 그래프 사이에 안내가 뜬다.
            AgentCardView(
                agent: Agent(provider: .claude, accountLabel: "pro"),
                snapshot: AgentSnapshot(
                    windows: [
                        UsageWindow(label: "Current session", usedPercent: 62,
                                    resetsAt: Date().addingTimeInterval(2 * 3600),
                                    kind: .session, windowSeconds: 5 * 3600),
                        UsageWindow(label: "Current week (all models)", usedPercent: 91,
                                    resetsAt: Date().addingTimeInterval(3 * 86400),
                                    kind: .weekly, windowSeconds: 7 * 86400),
                    ],
                    planLabel: "pro", fetchedAt: Date(),
                    error: "요청이 많아 대기 중입니다. 약 4분 후 재시도 · 아래 그래프는 갱신되지 않습니다."),
                isLoading: false,
                serviceHealth: .operational)
        }
        .padding(16)
    }
    .background(Term.bg)
}
