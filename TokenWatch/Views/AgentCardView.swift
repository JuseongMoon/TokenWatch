//
//  AgentCardView.swift
//  TokenWatch
//
//  리스트의 한 행: 에이전트 이름 + 원형 게이지들.
//

import SwiftUI

struct AgentCardView: View {
    let agent: Agent
    let snapshot: AgentSnapshot?
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let snapshot, let error = snapshot.error {
                errorRow(error)
            } else if let snapshot, !snapshot.windows.isEmpty {
                ringsRow(snapshot.windows)
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 92)
            } else {
                Text("사용량 데이터 없음")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 92)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: agent.provider.symbolName)
                .font(.title3)
                .foregroundStyle(agent.provider.accentColor)
                .frame(width: 32, height: 32)
                .background(agent.provider.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.provider.displayName)
                    .font(.headline)
                if let label = agent.accountLabel {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isLoading {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func ringsRow(_ windows: [UsageWindow]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(windows) { window in
                UsageBar(window: window)
            }
        }
    }

    private func errorRow(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
