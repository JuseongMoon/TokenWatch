//
//  SettingsSheet.swift
//  TokenWatch
//
//  설정(터미널 스타일): 계정 관리 · 자동 새로고침 주기 · 화면 항상 켬 · 앱 정보.
//

import SwiftUI

/// 하트비트 추적 대상 후보 한 개 = (에이전트, 게이지 창). 그래프 피커의 한 행.
private struct GraphOption: Identifiable {
    let agent: Agent
    let window: UsageWindow
    /// 에이전트 UUID + 창 라벨로 유일하게 식별(같은 라벨이 여러 계정에 있어도 구분).
    var id: String { "\(agent.id.uuidString)|\(window.label)" }
}

/// 자동 새로고침 주기 옵션(초). 0 = 꺼짐, -1 = Auto(적응형).
enum RefreshInterval: Int, CaseIterable, Identifiable {
    case off = 0
    case s30 = 30
    case s60 = 60
    case s300 = 300
    case auto = -1   // AutoRefreshPolicy.sentinel과 같아야 한다

    var id: Int { rawValue }

    /// 터미널 세그먼트용 짧은 라벨.
    var termLabel: String {
        switch self {
        case .off:  return "off"
        case .s30:  return "30s"
        case .s60:  return "60s"
        case .s300: return "5m"
        case .auto: return "auto"
        }
    }
}

struct SettingsSheet: View {
    @Environment(AgentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @AppStorage("tokenwatch.refreshInterval") private var refreshInterval = 60
    @AppStorage("tokenwatch.keepScreenOn") private var keepScreenOn = false
    @AppStorage(NotificationDefaults.sessionKey) private var notifySession = false
    @AppStorage(NotificationDefaults.weeklyKey) private var notifyWeekly = true
    @AppStorage("tokenwatch.hideUnusedWindows") private var hideUnusedWindows = false
    @AppStorage("tokenwatch.gaugeCritter") private var gaugeCritter = true
    /// 업무시간 스케줄(168자 "0/1"). 비어 있으면 기능 꺼짐(주간 마커 균일 흐름).
    @AppStorage(workHoursStorageKey) private var workHoursRaw = ""
    @AppStorage("tokenwatch.heartbeatCursor") private var heartbeatCursor = false
    @AppStorage("tokenwatch.heartbeatTracking") private var heartbeatTracking = false
    /// 다중 선택된 추적 대상. GraphOption.id("uuid|label")들을 개행으로 이어 저장.
    @AppStorage("tokenwatch.heartbeatTargets") private var heartbeatTargetsRaw = ""
    @AppStorage(appLanguageStorageKey) private var appLanguage: AppLanguage = .system
    /// 익명 사용 통계 수집 동의(기본 ON). AnalyticsService와 같은 키를 공유한다.
    @AppStorage(AnalyticsService.enabledKey) private var analyticsEnabled = true

    private var loc: L10n { L10n(lang: appLanguage.resolved) }

    /// 로그아웃 확인 다이얼로그의 대상 에이전트. nil이면 다이얼로그 미표시.
    @State private var pendingLogout: Agent?
    /// 알림 권한이 거부된 상태인지(설정 안내 표시용). NOTIFICATIONS 박스가 나타날 때 갱신.
    @State private var notifDenied = false
    /// 업무시간 설정 모달 표시 여부.
    @State private var showingWorkHours = false

    var body: some View {
        NavigationStack {
            ZStack {
                Term.bg.ignoresSafeArea()
                ScrollView(.vertical) {
                    VStack(spacing: 16) {
                        accountSection
                        demoSection
                        languageSection
                        refreshSection
                        displaySection
                        workHoursSection
                        heartbeatSection
                        notificationSection
                        screenSection
                        privacySection
                        infoSection
                    }
                    .padding(16)
                    // 콘텐츠 폭을 스크롤 컨테이너 폭에 고정 → 가로 스크롤 여지 제거(상하 전용)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle("SETTINGS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Term.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                PlainToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("[done]")
                            .font(.term(13, weight: .semibold))
                            .foregroundStyle(Term.green)
                            .fixedSize()   // 좁은 툴바 폭에서 마지막 ']'만 줄바꿈되는 것 방지
                    }
                    .buttonStyle(.plain)   // iOS 26 Liquid Glass 알약 배경 제거 → 터미널 테마 유지
                }
            }
        }
        .tint(Term.green)
        .onAppear { AnalyticsService.shared.log(.screenView(.settings)) }
        .onChange(of: notifySession) { _, _ in Task { await store.reapplyNotificationSchedule() } }
        .onChange(of: notifyWeekly) { _, _ in Task { await store.reapplyNotificationSchedule() } }
        .terminalConfirm(
            item: $pendingLogout,
            title: { _ in loc.logoutConfirmTitle },
            accountLabel: { $0.accountLabel },
            message: { loc.logoutMessage(provider: $0.provider.displayName) },
            confirmLabel: "[ \(loc.logout) ]",
            cancelLabel: "[ \(loc.cancel) ]",
            onConfirm: { store.remove($0) }
        )
        .overlay {
            if showingWorkHours {
                WorkHoursEditor(isPresented: $showingWorkHours)
            }
        }
        .animation(.snappy(duration: 0.22), value: showingWorkHours)
    }

    // MARK: 계정

    private var accountSection: some View {
        TerminalBox(title: "ACCOUNTS") {
            VStack(alignment: .leading, spacing: 12) {
                if store.agents.isEmpty {
                    Text("no accounts connected")
                        .font(.term(12)).foregroundStyle(Term.dim)
                } else {
                    ForEach(store.agents) { agent in
                        HStack(spacing: 8) {
                            Text(agent.provider.terminalTag)
                                .foregroundStyle(agent.provider.terminalColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(agent.provider.displayName.uppercased())
                                    .font(.term(13, weight: .semibold)).foregroundStyle(Term.fg)
                                if let label = agent.accountLabel, !label.isEmpty {
                                    Text(label).font(.term(10)).foregroundStyle(Term.dim)
                                }
                            }
                            Spacer()
                            // 데모 중에는 지울 토큰이 없다 — 표본 카드에 로그아웃을 노출하지 않는다.
                            if !store.isDemo {
                                Button {
                                    pendingLogout = agent
                                } label: {
                                    Text("[logout]").font(.term(12)).foregroundStyle(Term.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .font(.term(13))
                    }
                }
            }
        }
    }

    // MARK: 데모 (로그인 없이 둘러보기)

    /// 계정이 있든 없든 언제나 데모를 켜고 끌 수 있는 진입점.
    /// 메인 화면의 빈 목록 셀과 함께 두 갈래 발견 경로를 만든다.
    private var demoSection: some View {
        TerminalBox(title: "DEMO", titleColor: Term.yellow) {
            VStack(alignment: .leading, spacing: 10) {
                TerminalButton(title: store.isDemo ? "[ ■ EXIT DEMO ]" : "[ ▶ RUN DEMO ]",
                               color: Term.yellow,
                               dashedBorder: !store.isDemo) { toggleDemo() }
                    .accessibilityLabel(store.isDemo ? loc.a11yExitDemo : loc.a11yRunDemo)
                Text(store.isDemo ? loc.demoBanner : loc.demoHint)
                    .font(.term(10)).foregroundStyle(Term.dim)
            }
        }
    }

    /// 데모를 켜거나 끄고, 바뀐 화면을 곧바로 볼 수 있도록 설정을 닫는다.
    /// 자동 새로고침을 다시 걸어야 데모 게이지가 움직이고, 나갈 때는 실제 사용량을 즉시 다시 읽는다.
    private func toggleDemo() {
        if store.isDemo {
            AnalyticsService.shared.log(.demoEnd)
            store.exitDemo()
        } else {
            AnalyticsService.shared.log(.demoStart(source: .settings))
            store.enterDemo()
        }
        store.startAutoRefresh(interval: refreshInterval)
        dismiss()
    }

    /// 설정 변경을 기록하고 설정 파생 유저 속성을 함께 갱신한다(드리프트 방지).
    private func logSetting(_ setting: String, _ value: String) {
        AnalyticsService.shared.log(.settingChange(setting: setting, value: value))
        AnalyticsService.shared.syncSettingsProperties()
    }

    private func onOff(_ v: Bool) -> String { v ? "on" : "off" }

    // MARK: 언어 (세그먼트)

    private var languageSection: some View {
        TerminalBox(title: "LANGUAGE") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 0) {
                    ForEach(AppLanguage.allCases) { opt in
                        let selected = appLanguage == opt
                        Button {
                            appLanguage = opt
                            logSetting("language", langTag(opt))
                        } label: {
                            Text(opt.segmentLabel)
                                .font(.term(13, weight: selected ? .bold : .regular))
                                .foregroundStyle(selected ? Term.green : Term.dim)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(selected ? Term.green.opacity(0.14) : Color.clear)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .overlay(Rectangle().stroke(Term.dim.opacity(0.5), lineWidth: 1))

                Text(loc.settingsLanguageHelp)
                    .font(.term(10)).foregroundStyle(Term.dim)
            }
        }
    }

    // MARK: 새로고침 (세그먼트)

    private var refreshSection: some View {
        TerminalBox(title: "AUTO-REFRESH") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 0) {
                    ForEach(RefreshInterval.allCases) { opt in
                        let selected = refreshInterval == opt.rawValue
                        Button {
                            refreshInterval = opt.rawValue
                            logSetting("refresh_interval", opt.termLabel)
                        } label: {
                            Text(opt.termLabel)
                                .font(.term(13, weight: selected ? .bold : .regular))
                                .foregroundStyle(selected ? Term.green : Term.dim)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(selected ? Term.green.opacity(0.14) : Color.clear)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .overlay(Rectangle().stroke(Term.dim.opacity(0.5), lineWidth: 1))

                Text(loc.settingsRefreshHelp)
                    .font(.term(10)).foregroundStyle(Term.dim)

                if refreshInterval == RefreshInterval.auto.rawValue {
                    Text(loc.settingsRefreshAutoHelp(currentAutoLabel))
                        .font(.term(10)).foregroundStyle(Term.cyan)
                }
            }
        }
    }

    /// Auto 모드의 현재 유효 간격 라벨(예: "30s", "2m").
    private var currentAutoLabel: String {
        let s = store.autoIntervalSeconds
        return s < 60 ? "\(s)s" : "\(s / 60)m"
    }

    // MARK: 표시 (체크박스)

    private var displaySection: some View {
        TerminalBox(title: "DISPLAY") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        hideUnusedWindows.toggle()
                        logSetting("hide_unused", onOff(hideUnusedWindows))
                    } label: {
                        HStack(spacing: 8) {
                            Text(hideUnusedWindows ? "[x]" : "[ ]")
                                .foregroundStyle(hideUnusedWindows ? Term.green : Term.dim)
                            Text("hide unused (0%) graphs").foregroundStyle(Term.fg)
                            Spacer()
                        }
                        .font(.term(14))
                    }
                    .buttonStyle(.plain)

                    Text(loc.settingsHideUnusedHelp)
                        .font(.term(10)).foregroundStyle(Term.dim)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        gaugeCritter.toggle()
                        logSetting("gauge_critter", onOff(gaugeCritter))
                    } label: {
                        HStack(spacing: 8) {
                            Text(gaugeCritter ? "[x]" : "[ ]")
                                .foregroundStyle(gaugeCritter ? Term.green : Term.dim)
                            Text("gauge slime").foregroundStyle(Term.fg)
                            AnimatedPixelSpriteView(sprite: .slime, cell: 2,
                                                    flatColor: gaugeCritter ? nil : Term.dim)
                            Spacer()
                        }
                        .font(.term(14))
                    }
                    .buttonStyle(.plain)

                    Text(loc.settingsGaugeCritterHelp)
                        .font(.term(10)).foregroundStyle(Term.dim)
                }
            }
        }
    }

    // MARK: 업무시간

    /// 설정 버튼 옆 요약 라벨("설정 안 됨" 또는 "주 N시간").
    private var workHoursSummaryLabel: String {
        let s = WorkHoursSchedule(encoded: workHoursRaw)
        return s.isEmpty ? loc.workHoursNotSet : loc.workHoursSummary(hours: s.onHours)
    }

    private var workHoursSection: some View {
        TerminalBox(title: "WORK HOURS") {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    showingWorkHours = true
                } label: {
                    HStack(spacing: 8) {
                        Text(loc.workHoursButton).foregroundStyle(Term.green)
                        Spacer()
                        Text(workHoursSummaryLabel).foregroundStyle(Term.dim)
                    }
                    .font(.term(14))
                }
                .buttonStyle(.plain)

                Text(loc.settingsWorkHoursHelp)
                    .font(.term(10)).foregroundStyle(Term.dim)
            }
        }
    }

    // MARK: 하트비트 커서

    /// 추적 대상 후보: 추가된 모든 에이전트의 게이지(그래프) 창.
    /// hide unused 설정과 무관하게 0% 창도 전부 포함한다.
    private var trackableGraphs: [GraphOption] {
        store.agents.flatMap { agent in
            (store.snapshots[agent.id]?.windows ?? [])
                .filter { $0.isGaugeLike }
                .map { GraphOption(agent: agent, window: $0) }
        }
    }

    /// 저장된 다중 선택 대상 ID 집합.
    private var selectedTargetIDs: Set<String> {
        Set(heartbeatTargetsRaw.split(separator: "\n").map(String.init))
    }

    /// 대상 하나를 선택/해제 토글. 정렬해 저장(순서 안정 → 불필요한 갱신 방지).
    private func toggleTarget(_ id: String) {
        var ids = selectedTargetIDs
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        heartbeatTargetsRaw = ids.sorted().joined(separator: "\n")
    }

    /// 현재 저장된 선택 중 하나라도 실제 후보 목록에 존재하는지.
    private var hasValidTarget: Bool {
        !selectedTargetIDs.isDisjoint(with: Set(trackableGraphs.map(\.id)))
    }

    /// usage 모드로 전환. 유효한 선택이 없으면 첫 후보를 기본 선택한다.
    private func selectUsageMode() {
        heartbeatTracking = true
        if !hasValidTarget, let first = trackableGraphs.first {
            heartbeatTargetsRaw = first.id
        }
    }

    private var heartbeatSection: some View {
        TerminalBox(title: "HEARTBEAT") {
            VStack(alignment: .leading, spacing: 14) {
                // on/off
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        heartbeatCursor.toggle()
                        logSetting("heartbeat", heartbeatCursor ? (heartbeatTracking ? "usage" : "heart") : "off")
                    } label: {
                        HStack(spacing: 8) {
                            Text(heartbeatCursor ? "[x]" : "[ ]")
                                .foregroundStyle(heartbeatCursor ? Term.green : Term.dim)
                            Text("heartbeat cursor").foregroundStyle(Term.fg)
                            PixelHeart(flatColor: heartbeatCursor ? nil : Term.dim, size: 15)
                            Spacer()
                        }
                        .font(.term(14))
                    }
                    .buttonStyle(.plain)

                    Text(loc.settingsHeartbeatHelp)
                        .font(.term(10)).foregroundStyle(Term.dim)
                }

                if heartbeatCursor {
                    // 모드: heart(단일) / usage(사용량 추적)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 0) {
                            modeButton("heart", selected: !heartbeatTracking) {
                                heartbeatTracking = false
                                logSetting("heartbeat", "heart")
                            }
                            modeButton("usage", selected: heartbeatTracking) {
                                selectUsageMode()
                                logSetting("heartbeat", "usage")
                            }
                        }
                        .overlay(Rectangle().stroke(Term.dim.opacity(0.5), lineWidth: 1))

                        Text(loc.settingsHeartbeatModeHelp)
                            .font(.term(10)).foregroundStyle(Term.dim)
                    }

                    if heartbeatTracking {
                        graphPicker
                    }
                }
            }
        }
    }

    private func modeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.term(13, weight: selected ? .bold : .regular))
                .foregroundStyle(selected ? Term.green : Term.dim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(selected ? Term.green.opacity(0.14) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private var graphPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("track graph")
                .font(.term(11, weight: .semibold)).foregroundStyle(Term.cyan)

            let graphs = trackableGraphs
            if graphs.isEmpty {
                Text(loc.settingsHeartbeatNoGraphs)
                    .font(.term(11)).foregroundStyle(Term.dim)
            } else {
                ForEach(graphs) { g in
                    let selected = selectedTargetIDs.contains(g.id)
                    Button {
                        toggleTarget(g.id)
                    } label: {
                        HStack(spacing: 8) {
                            Text(selected ? "[v]" : "[ ]")
                                .foregroundStyle(selected ? Term.green : Term.dim)
                            Text(g.agent.provider.terminalTag)
                                .foregroundStyle(g.agent.provider.terminalColor)
                            Text(g.window.label)
                                .foregroundStyle(selected ? Term.fg : Term.dim)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text("\(Int(g.window.usedPercent.rounded()))%")
                                .foregroundStyle(Term.statusColor(remainingPercent: g.window.remainingPercent))
                                .monospacedDigit()
                        }
                        .font(.term(12))
                    }
                    .buttonStyle(.plain)
                }

                Text(loc.settingsHeartbeatMultiHelp)
                    .font(.term(10)).foregroundStyle(Term.dim)
            }
        }
    }

    // MARK: 알림 (체크박스)

    private var notificationSection: some View {
        TerminalBox(title: "NOTIFICATIONS") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    notifToggle("session resets", isOn: notifySession) {
                        notifySession.toggle()
                        logSetting("notify_session", onOff(notifySession))
                    }
                    notifToggle("weekly resets", isOn: notifyWeekly) {
                        notifyWeekly.toggle()
                        logSetting("notify_weekly", onOff(notifyWeekly))
                    }
                    Text(loc.settingsNotifHelp)
                        .font(.term(10)).foregroundStyle(Term.dim)
                }
                if notifDenied {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(loc.settingsNotifDenied)
                            .font(.term(10)).foregroundStyle(Term.red)
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Text(loc.settingsNotifOpenSettings)
                                .font(.term(12)).foregroundStyle(Term.cyan)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task { notifDenied = await NotificationManager.shared.isDenied() }
    }

    private func notifToggle(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(isOn ? "[x]" : "[ ]")
                    .foregroundStyle(isOn ? Term.green : Term.dim)
                Text(title).foregroundStyle(Term.fg)
                Spacer()
            }
            .font(.term(14))
        }
        .buttonStyle(.plain)
    }

    // MARK: 화면 (체크박스)

    private var screenSection: some View {
        TerminalBox(title: "SCREEN") {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    keepScreenOn.toggle()
                    logSetting("keep_screen_on", onOff(keepScreenOn))
                } label: {
                    HStack(spacing: 8) {
                        Text(keepScreenOn ? "[x]" : "[ ]")
                            .foregroundStyle(keepScreenOn ? Term.green : Term.dim)
                        Text("keep screen on").foregroundStyle(Term.fg)
                        Spacer()
                    }
                    .font(.term(14))
                }
                .buttonStyle(.plain)

                Text(loc.settingsScreenHelp)
                    .font(.term(10)).foregroundStyle(Term.dim)
            }
        }
    }

    // MARK: 프라이버시 (익명 통계 옵트아웃)

    /// 세그먼트 라벨용 언어 태그(유저 속성 app_lang과 같은 표기).
    private func langTag(_ opt: AppLanguage) -> String {
        switch opt {
        case .system: return "system"
        case .korean: return "ko"
        case .english: return "en"
        }
    }

    private var privacySection: some View {
        TerminalBox(title: "PRIVACY") {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    analyticsEnabled.toggle()
                    AnalyticsService.shared.setEnabled(analyticsEnabled)
                    // 다시 켤 때는 속성을 곧바로 재동기화한다(꺼져 있던 동안의 드리프트 복구).
                    if analyticsEnabled { AnalyticsService.shared.syncUserProperties(agents: store.agents) }
                } label: {
                    HStack(spacing: 8) {
                        Text(analyticsEnabled ? "[x]" : "[ ]")
                            .foregroundStyle(analyticsEnabled ? Term.green : Term.dim)
                        Text("share anonymous usage stats").foregroundStyle(Term.fg)
                        Spacer()
                    }
                    .font(.term(14))
                }
                .buttonStyle(.plain)

                Text(loc.settingsAnalyticsHelp)
                    .font(.term(10)).foregroundStyle(Term.dim)
            }
        }
    }

    // MARK: 정보

    private var infoSection: some View {
        TerminalBox(title: "INFO") {
            KVRow(key: "version", value: appVersion, keyWidth: 84)
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

#Preview {
    SettingsSheet().environment(AgentStore())
}

#Preview("demo mode") {
    let store = AgentStore()
    store.enterDemo()
    return SettingsSheet().environment(store)
}
