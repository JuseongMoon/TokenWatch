//
//  ContentView.swift
//  TokenWatch
//
//  메인 화면(터미널 스타일): 상단 프롬프트 헤더 + 에이전트 카드 리스트 +
//  하단 추가 셀. 우측 상단 [SETTINGS] 설정 버튼.
//

import SwiftUI

struct ContentView: View {
    @Environment(AgentStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("tokenwatch.refreshInterval") private var refreshInterval = 60
    @AppStorage("tokenwatch.keepScreenOn") private var keepScreenOn = false
    @AppStorage(appLanguageStorageKey) private var appLanguage: AppLanguage = .system

    private var loc: L10n { L10n(lang: appLanguage.resolved) }

    @State private var showingAdd = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                Term.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    topBar   // 앱 이름·상태 라인·[SETTINGS] 를 최상단에 고정
                    list     // 아래 리스트만 스크롤
                }
            }
            // 시스템 네비바를 숨기고 상단 배너를 직접 고정한다(두 줄 배너를 위해 커스텀 바 사용).
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingAdd) {
                AddAgentSheet().environment(store)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsSheet().environment(store)
            }
        }
        .tint(Term.green)
        // 씬 라이프사이클: 활성일 때만 자동 새로고침 + 화면 유지.
        .onChange(of: scenePhase, initial: true) { _, phase in
            applyScenePhase(phase)
        }
        .onChange(of: refreshInterval) { _, _ in
            if scenePhase == .active { store.startAutoRefresh(interval: refreshInterval) }
        }
        .onChange(of: keepScreenOn) { _, _ in
            if scenePhase == .active { UIApplication.shared.isIdleTimerDisabled = keepScreenOn }
        }
    }

    private func applyScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            store.startAutoRefresh(interval: refreshInterval)
            UIApplication.shared.isIdleTimerDisabled = keepScreenOn
        default:
            store.stopAutoRefresh()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: 상단 고정 바

    /// 화면 최상단에 고정되는 상단 바 — 앱 이름·상태 라인·[SETTINGS] 모두 스크롤과 무관하게 고정.
    private var topBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                appNameLine
                statusPrompt
            }
            Spacer(minLength: 8)
            Button {
                showingSettings = true
            } label: {
                Text("[SETTINGS]")
                    .font(.term(13, weight: .semibold))
                    .foregroundStyle(Term.cyan)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc.a11ySettings)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Term.bg)
    }

    /// 앱 이름 라인 (`tokenwatch v1.0`).
    private var appNameLine: some View {
        HStack(spacing: 0) {
            Text("token").foregroundStyle(Term.green)
            Text("watch").foregroundStyle(Term.cyan)
            Text("  v\(appVersion)")
                .font(.term(11)).foregroundStyle(Term.dim)
        }
        .font(.term(19, weight: .bold))
        .terminalGlow(Term.green, radius: 2)
    }

    /// 상태 프롬프트 라인 (`$ watching N agents _`).
    private var statusPrompt: some View {
        HStack(spacing: 6) {
            Text("$").foregroundStyle(Term.dim)
            Text(statusLine).foregroundStyle(Term.fg)
            BlinkingCursor(symbol: "_", color: Term.green, size: 13)
        }
        .font(.term(12))
    }

    private var statusLine: String {
        let n = store.agents.count
        return n == 0 ? "no agents connected" : "watching \(n) agent\(n == 1 ? "" : "s")"
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    // MARK: 리스트

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if store.agents.isEmpty {
                    emptyHint
                }
                ForEach(Array(store.agents.enumerated()), id: \.element.id) { index, agent in
                    ZStack(alignment: .topTrailing) {
                        NavigationLink {
                            AgentDetailView(agent: agent).environment(store)
                        } label: {
                            AgentCardView(
                                agent: agent,
                                snapshot: store.snapshots[agent.id],
                                isLoading: store.loadingIDs.contains(agent.id)
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(loc.menuRefresh, systemImage: "arrow.clockwise") {
                                Task { await store.refresh(agent) }
                            }
                            Button(loc.menuDelete, systemImage: "trash", role: .destructive) {
                                store.remove(agent)
                            }
                        }

                        // 카드 위에 겹쳐 놓는 순서 변경 화살표(NavigationLink와 별도 레이어라 탭 충돌 없음).
                        reorderControls(agent: agent, index: index)
                    }
                }
                AddAgentCell { showingAdd = true }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .background(Term.bg)
        .refreshable {
            await store.refreshAll()
        }
    }

    // MARK: 순서 변경 화살표

    /// 카드 우상단에 겹쳐 놓는 정렬 컨트롤(왼쪽 ▲ 위로 / 오른쪽 ▼ 아래로).
    /// 배경색을 깔아 타이틀 위에 떠도 가독성을 유지하고, 경계 항목은 해당 화살표를 흐리게 비활성한다.
    private func reorderControls(agent: Agent, index: Int) -> some View {
        HStack(spacing: 2) {
            reorderArrow("▲", disabled: index == 0, label: loc.a11yMoveUp) {
                store.moveUp(agent)
            }
            reorderArrow("▼", disabled: index == store.agents.count - 1, label: loc.a11yMoveDown) {
                store.moveDown(agent)
            }
        }
        .padding(4)
        .background(Term.bg)
        .padding(.top, 7)
        .padding(.trailing, 8)
    }

    private func reorderArrow(_ glyph: String, disabled: Bool, label: String,
                              action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) { action() }
        } label: {
            Text(glyph)
                .font(.term(11))
                .foregroundStyle(disabled ? Term.dim.opacity(0.3) : Term.green)
                .frame(width: 26, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("$ tap").foregroundStyle(Term.dim)
                Text("[+ ADD AGENT]").foregroundStyle(Term.green)
                Text("below to login").foregroundStyle(Term.dim)
            }
            Text("  tokens are stored only on this device")
                .foregroundStyle(Term.dim.opacity(0.7))
        }
        .font(.term(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 20)
    }
}

#Preview {
    ContentView().environment(AgentStore())
}
