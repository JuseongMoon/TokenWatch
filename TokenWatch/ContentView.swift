//
//  ContentView.swift
//  TokenWatch
//
//  메인 화면(터미널 스타일): 상단 프롬프트 헤더 + 에이전트 카드 리스트 +
//  하단 추가 셀. 우측 상단 [CFG] 설정 버튼.
//

import SwiftUI

struct ContentView: View {
    @Environment(AgentStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("tokenwatch.refreshInterval") private var refreshInterval = 60
    @AppStorage("tokenwatch.keepScreenOn") private var keepScreenOn = false

    @State private var showingAdd = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                Term.bg.ignoresSafeArea()
                list
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Term.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Text("[CFG]")
                            .font(.term(13, weight: .semibold))
                            .foregroundStyle(Term.cyan)
                    }
                    .accessibilityLabel("설정")
                }
            }
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

    // MARK: 헤더 (프롬프트 배너)

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Text("token").foregroundStyle(Term.green)
                Text("watch").foregroundStyle(Term.cyan)
                Text("  v\(appVersion)")
                    .font(.term(11)).foregroundStyle(Term.dim)
            }
            .font(.term(21, weight: .bold))
            .terminalGlow(Term.green, radius: 3)

            HStack(spacing: 6) {
                Text("$").foregroundStyle(Term.dim)
                Text(statusLine).foregroundStyle(Term.fg)
                BlinkingCursor(symbol: "_", color: Term.green, size: 13)
                Spacer(minLength: 0)
            }
            .font(.term(12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                header
                    .padding(.top, 4)
                    .padding(.bottom, 6)

                if store.agents.isEmpty {
                    emptyHint
                }
                ForEach(store.agents) { agent in
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
                        Button("새로고침", systemImage: "arrow.clockwise") {
                            Task { await store.refresh(agent) }
                        }
                        Button("삭제", systemImage: "trash", role: .destructive) {
                            store.remove(agent)
                        }
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
