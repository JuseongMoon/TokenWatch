//
//  ContentView.swift
//  TokenWatch
//
//  메인 화면(터미널 스타일): 상단 프롬프트 헤더 + 에이전트 카드 리스트 +
//  하단 추가 셀. 우측 상단에 공지함 [✉]·설정 [⚙] 버튼.
//

import SwiftUI

struct ContentView: View {
    @Environment(AgentStore.self) private var store
    @Environment(AnnouncementStore.self) private var announcements
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("tokenwatch.refreshInterval") private var refreshInterval = 60
    @AppStorage("tokenwatch.keepScreenOn") private var keepScreenOn = false
    @AppStorage("tokenwatch.heartbeatCursor") private var heartbeatCursor = false
    @AppStorage("tokenwatch.heartbeatTracking") private var heartbeatTracking = false
    @AppStorage("tokenwatch.heartbeatTargets") private var heartbeatTargetsRaw = ""
    @AppStorage(appLanguageStorageKey) private var appLanguage: AppLanguage = .system

    private var loc: L10n { L10n(lang: appLanguage.resolved) }

    @State private var showingAdd = false
    @State private var showingSettings = false
    @State private var showingAnnouncements = false

    /// 시트가 하나라도 떠 있는지 — 공지 팝업 보류 판단에 쓴다(아래 overlay 주석 참고).
    private var sheetShowing: Bool { showingAdd || showingSettings || showingAnnouncements }

    var body: some View {
        NavigationStack {
            ZStack {
                Term.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    topBar   // 앱 이름·상태 라인·[✉]·[⚙] 를 최상단에 고정
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
            .sheet(isPresented: $showingAnnouncements) {
                AnnouncementListSheet().environment(announcements)
            }
        }
        .tint(Term.green)
        // 서버 공지 팝업. NavigationStack 바깥에 얹어 push된 상세 화면 위에도 뜬다.
        // 시트(추가/설정/공지함)는 UIKit 프레젠테이션이라 이 오버레이를 덮으므로, 시트가 열려 있으면
        // 보류하고 닫힌 뒤에 뜬다(로그인 퍼널을 가로막지 않기 위해서도).
        .overlay {
            if let announcement = announcements.presented, !sheetShowing {
                AnnouncementOverlay(announcement: announcement)
            }
        }
        .animation(.snappy(duration: 0.22), value: announcements.presented?.id)
        // 씬 라이프사이클: 활성일 때만 자동 새로고침. 화면 유지는 전면(.active/.inactive)에서
        // 유지하고 백그라운드에서만 해제한다(아래 applyIdleTimer 참고).
        .onChange(of: scenePhase, initial: true) { _, phase in
            applyScenePhase(phase)
        }
        .onChange(of: refreshInterval) { _, _ in
            if scenePhase == .active { store.startAutoRefresh(interval: refreshInterval) }
        }
        .onChange(of: keepScreenOn) { _, _ in
            applyIdleTimer(phase: scenePhase)
        }
        .onAppear { AnalyticsService.shared.log(.screenView(.main)) }
    }

    private func applyScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            store.startAutoRefresh(interval: refreshInterval)
            // 콜드 스타트(initial: true)와 포그라운드 복귀 모두 여기를 지난다. 스로틀은 스토어가 판단.
            announcements.check()
        default:
            store.stopAutoRefresh()
        }
        // 백그라운드로 나갈 때, 이벤트성 리셋 감지를 위한 백그라운드 새로고침을 예약한다.
        if phase == .background {
            BackgroundRefreshScheduler.schedule(earliestBegin: store.nextResetDate())
        }
        applyIdleTimer(phase: phase)
    }

    /// 화면 유지 플래그를 현재 상태로부터 재계산해 적용한다.
    /// 전면(.active/.inactive)에서는 설정대로, 완전한 백그라운드에서만 해제한다.
    /// `.inactive`(제어센터·알림 배너·시스템 알림·수신 전화 등 일시적 전면 중단)에서 플래그를
    /// 끄지 않아, 잠깐의 중단이 화면 유지를 무너뜨리지 않게 한다.
    private func applyIdleTimer(phase: ScenePhase) {
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn && phase != .background
    }

    // MARK: 상단 고정 바

    /// 화면 최상단에 고정되는 상단 바 — 앱 이름·상태 라인·[✉]·[⚙] 모두 스크롤과 무관하게 고정.
    private var topBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                appNameLine
                statusPrompt
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                announcementsButton
                TerminalGlyphButton(systemImage: "gearshape") { showingSettings = true }
                    .accessibilityLabel(loc.a11ySettings)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Term.bg)
    }

    /// 공지함 버튼. 안 읽은 공지가 있으면 우상단에 초록 점을 얹는다(개수는 접근성 라벨로만 읽어준다).
    private var announcementsButton: some View {
        let unread = announcements.unreadCount
        return TerminalGlyphButton(systemImage: "envelope") { showingAnnouncements = true }
            .overlay(alignment: .topTrailing) {
                if unread > 0 {
                    Circle()
                        .fill(Term.green)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -2)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(loc.a11yAnnouncements(unread: unread))
    }

    /// `tokenwatch` 타이틀의 글자별 색 — 참조 이미지 `ultrathink`의 파스텔 무지개
    /// (xterm-256 팔레트)를 글자 순서 그대로 t·o·k·e·n·w·a·t·c·h 에 대응시킨다.
    private static let titleColors: [Color] = [
        Color(red: 1.000, green: 0.529, blue: 0.529),   // t  #FF8787
        Color(red: 1.000, green: 0.686, blue: 0.529),   // o  #FFAF87
        Color(red: 1.000, green: 0.843, blue: 0.529),   // k  #FFD787
        Color(red: 0.686, green: 0.843, blue: 0.686),   // e  #AFD7AF
        Color(red: 0.686, green: 0.686, blue: 0.843),   // n  #AFAFD7
        Color(red: 0.686, green: 0.686, blue: 0.843),   // w  #AFAFD7
        Color(red: 0.843, green: 0.686, blue: 0.843),   // a  #D7AFD7
        Color(red: 1.000, green: 0.529, blue: 0.529),   // t  #FF8787
        Color(red: 1.000, green: 0.686, blue: 0.529),   // c  #FFAF87
        Color(red: 1.000, green: 0.843, blue: 0.529),   // h  #FFD787
    ]

    /// 앱 이름 라인 (`tokenwatch v1.0`). 글자마다 titleColors 색과 같은 색의 글로우.
    private var appNameLine: some View {
        HStack(spacing: 0) {
            ForEach(Array("tokenwatch".enumerated()), id: \.offset) { i, ch in
                Text(String(ch))
                    .foregroundStyle(Self.titleColors[i])
                    .terminalGlow(Self.titleColors[i], radius: 2)
            }
            Text("  v\(appVersion)")
                .font(.term(11)).foregroundStyle(Term.dim)
        }
        .font(.term(19, weight: .bold))
    }

    /// 상태 프롬프트 라인 (`$ watching N agents _`).
    private var statusPrompt: some View {
        HStack(spacing: 6) {
            Text("$").foregroundStyle(Term.dim)
            Text(statusLine).foregroundStyle(Term.fg)
            cursor
        }
        .font(.term(12))
    }

    /// 상태 프롬프트 끝의 커서. 하트비트 설정에 따라 언더바 / 단일 하트 / 사용량 추적 하트 바.
    @ViewBuilder
    private var cursor: some View {
        if heartbeatCursor {
            if let used = trackedUsedPercent {
                HeartHealthBar(usedPercent: used, size: 11)
            } else {
                BlinkingHeart(size: 11)   // 추적 꺼짐 또는 대상 미해석 시 단일 하트
            }
        } else {
            BlinkingCursor(symbol: "_", color: Term.green, size: 13)
        }
    }

    /// 추적 대상으로 선택된 그래프(gauge 창)들의 사용률 기준값(0...100). 대상이 없거나 못 찾으면 nil.
    /// 여러 개를 선택하면 각 그래프 잔여율의 평균 = 사용률의 평균을 기준으로 삼는다
    /// (예: 40·50·60% 잔여 → 50% 기준). 하나만 선택하면 그 값 그대로.
    private var trackedUsedPercent: Double? {
        guard heartbeatTracking else { return nil }
        let ids = Set(heartbeatTargetsRaw.split(separator: "\n").map(String.init))
        guard !ids.isEmpty else { return nil }

        // 선택된 게이지 창들의 usedPercent 수집. ID 형식은 SettingsSheet의 GraphOption.id("uuid|label")와 일치.
        var used: [Double] = []
        for agent in store.agents {
            for window in store.snapshots[agent.id]?.windows ?? [] where window.isGaugeLike {
                if ids.contains("\(agent.id.uuidString)|\(window.label)") {
                    used.append(window.usedPercent)
                }
            }
        }
        guard !used.isEmpty else { return nil }
        return used.reduce(0, +) / Double(used.count)
    }

    private var statusLine: String {
        if store.isDemo { return "demo mode · sample data" }
        let n = store.agents.count
        return n == 0 ? "no agents connected" : "watching \(n) agent\(n == 1 ? "" : "s")"
    }

    /// 데모 시작: 표본 데이터로 갈아끼운 뒤 자동 새로고침을 다시 걸어 게이지가 살아 움직이게 한다.
    private func enterDemo() {
        AnalyticsService.shared.log(.demoStart(source: .emptyList))
        store.enterDemo()
        if scenePhase == .active { store.startAutoRefresh(interval: refreshInterval) }
    }

    /// 데모 종료: 원래 상태로 되돌리고 실제 사용량을 곧바로 다시 조회한다.
    private func exitDemo() {
        AnalyticsService.shared.log(.demoEnd)
        store.exitDemo()
        if scenePhase == .active { store.startAutoRefresh(interval: refreshInterval) }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
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
                                isLoading: store.loadingIDs.contains(agent.id),
                                serviceHealth: store.serviceStatus[agent.provider]
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(loc.menuRefresh, systemImage: "arrow.clockwise") {
                                AnalyticsService.shared.log(.refreshManual(source: .contextMenu))
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
                if store.isDemo {
                    // 데모 중에는 로그인 진입점을 감춘다 — 표본 목록에 실계정을 섞지 않기 위함.
                    exitDemoCell
                } else {
                    AddAgentCell { showingAdd = true }
                    if store.agents.isEmpty { demoCell }
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .background(Term.bg)
        .refreshable {
            AnalyticsService.shared.log(.refreshManual(source: .pullList))
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
                .font(.term(16.5))
                .foregroundStyle(disabled ? Term.dim.opacity(0.3) : Term.green)
                .frame(width: 26, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    /// 아직 로그인한 에이전트가 없을 때만 뜨는 데모 진입 셀. 계정 없이도 앱이 무엇을
    /// 보여주는지 바로 확인할 수 있게 한다.
    private var demoCell: some View {
        VStack(spacing: 6) {
            TerminalButton(title: "[ ▶ RUN DEMO ]", color: Term.yellow,
                           dashedBorder: true) { enterDemo() }
                .accessibilityLabel(loc.a11yRunDemo)
            Text(loc.demoHint)
                .font(.term(11))
                .foregroundStyle(Term.dim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    /// 데모 중 목록 맨 아래에 서는 종료 셀. 상단 배너를 없앤 대신, 여기서
    /// "표본 데이터"라는 사실까지 함께 알린다(안내와 빠져나갈 수단을 한곳에).
    private var exitDemoCell: some View {
        VStack(spacing: 6) {
            TerminalButton(title: "[ ■ EXIT DEMO ]", color: Term.yellow) { exitDemo() }
                .accessibilityLabel(loc.a11yExitDemo)
            Text(loc.demoBanner)
                .font(.term(11))
                .foregroundStyle(Term.dim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
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

#Preview("demo mode") {
    let store = AgentStore()
    store.enterDemo()
    return ContentView().environment(store)
}
