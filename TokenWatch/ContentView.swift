//
//  ContentView.swift
//  TokenWatch
//
//  메인 화면: 추가된 에이전트 리스트 + 하단 추가 셀 + 우측 상단 설정 버튼.
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
            list
                .navigationTitle("TokenWatch")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
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

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if store.agents.isEmpty {
                    emptyHint
                }
                ForEach(store.agents) { agent in
                    AgentCardView(
                        agent: agent,
                        snapshot: store.snapshots[agent.id],
                        isLoading: store.loadingIDs.contains(agent.id)
                    )
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
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await store.refreshAll()
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("아래 버튼을 눌러 AI 에이전트에 로그인하고\n토큰 잔여량을 확인하세요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

#Preview {
    ContentView().environment(AgentStore())
}
