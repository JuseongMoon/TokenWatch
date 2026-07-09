//
//  SettingsSheet.swift
//  TokenWatch
//
//  설정: 계정 관리 · 자동 새로고침 주기 · 화면 항상 켬 · 앱 정보.
//

import SwiftUI

/// 자동 새로고침 주기 옵션(초). 0 = 꺼짐.
enum RefreshInterval: Int, CaseIterable, Identifiable {
    case off = 0
    case s30 = 30
    case s60 = 60
    case s300 = 300

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .off: return "꺼짐"
        case .s30: return "30초"
        case .s60: return "60초"
        case .s300: return "5분"
        }
    }
}

struct SettingsSheet: View {
    @Environment(AgentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @AppStorage("tokenwatch.refreshInterval") private var refreshInterval = 60
    @AppStorage("tokenwatch.keepScreenOn") private var keepScreenOn = false

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                refreshSection
                screenSection
                infoSection
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
    }

    private var accountSection: some View {
        Section("계정") {
            if store.agents.isEmpty {
                Text("추가된 계정이 없습니다")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.agents) { agent in
                    HStack {
                        Image(systemName: agent.provider.symbolName)
                            .foregroundStyle(agent.provider.accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(agent.provider.displayName)
                            if let label = agent.accountLabel {
                                Text(label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("로그아웃", role: .destructive) {
                            store.remove(agent)
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private var refreshSection: some View {
        Section {
            Picker("자동 새로고침", selection: $refreshInterval) {
                ForEach(RefreshInterval.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
        } header: {
            Text("새로고침")
        } footer: {
            Text("화면이 켜져 있을 때만 자동으로 갱신됩니다. 너무 짧으면 서버 제한(429)에 걸릴 수 있습니다.")
        }
    }

    private var screenSection: some View {
        Section {
            Toggle("화면 항상 켬", isOn: $keepScreenOn)
        } header: {
            Text("화면")
        } footer: {
            Text("켜면 앱을 보는 동안 화면이 자동으로 꺼지지 않습니다.")
        }
    }

    private var infoSection: some View {
        Section("정보") {
            HStack {
                Text("버전")
                Spacer()
                Text(appVersion).foregroundStyle(.secondary)
            }
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
