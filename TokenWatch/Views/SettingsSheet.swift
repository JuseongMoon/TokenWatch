//
//  SettingsSheet.swift
//  TokenWatch
//
//  설정(터미널 스타일): 계정 관리 · 자동 새로고침 주기 · 화면 항상 켬 · 앱 정보.
//

import SwiftUI

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
    @AppStorage("tokenwatch.hideUnusedWindows") private var hideUnusedWindows = false
    @AppStorage("tokenwatch.heartbeatCursor") private var heartbeatCursor = false
    @AppStorage(appLanguageStorageKey) private var appLanguage: AppLanguage = .system

    private var loc: L10n { L10n(lang: appLanguage.resolved) }

    var body: some View {
        NavigationStack {
            ZStack {
                Term.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        accountSection
                        languageSection
                        refreshSection
                        displaySection
                        screenSection
                        infoSection
                    }
                    .padding(16)
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
                            Button {
                                store.remove(agent)
                            } label: {
                                Text("[logout]").font(.term(12)).foregroundStyle(Term.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .font(.term(13))
                    }
                }
            }
        }
    }

    // MARK: 언어 (세그먼트)

    private var languageSection: some View {
        TerminalBox(title: "LANGUAGE") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 0) {
                    ForEach(AppLanguage.allCases) { opt in
                        let selected = appLanguage == opt
                        Button {
                            appLanguage = opt
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
                        heartbeatCursor.toggle()
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
            }
        }
    }

    // MARK: 화면 (체크박스)

    private var screenSection: some View {
        TerminalBox(title: "SCREEN") {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    keepScreenOn.toggle()
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
