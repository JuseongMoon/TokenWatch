//
//  UsageBar.swift
//  TokenWatch
//
//  리스트 카드 안 사용량 창 한 줄(터미널 스타일):
//  라벨(cyan) → [██████╎░░░] 게이지 → NN% used(상태색) → 리셋 요약(dim).
//

import SwiftUI

struct UsageBar: View {
    let window: UsageWindow

    private var usedFraction: Double { max(0, min(1, window.usedPercent / 100)) }
    private var statusColor: Color { Term.statusColor(remainingPercent: window.remainingPercent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(window.label.uppercased())
                .font(.term(11, weight: .semibold))
                .foregroundStyle(Term.cyan)

            // TimelineView로 네트워크 갱신과 무관하게 마커(현재 시각)가 흐르게 한다.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: 8) {
                    // 반응형: 남은 가로폭을 게이지가 최대한 채운다.
                    TerminalGauge(usedFraction: usedFraction,
                                  fillColor: statusColor,
                                  elapsedFraction: window.elapsedFraction(at: context.date),
                                  height: 14, bracketSize: 13)
                    // 퍼센트는 오른쪽 고정 — 3자리(100%)까지 자리를 확보해 바 길이가 흔들리지 않게.
                    Text("\(String(format: "%3d", Int(window.usedPercent.rounded())))% used")
                        .font(.term(12))
                        .monospacedDigit()
                        .foregroundStyle(statusColor)
                        .fixedSize()
                }
            }

            if window.resetsAt != nil {
                Text(window.resetSummary())
                    .font(.term(10))
                    .foregroundStyle(Term.dim)
            }
        }
    }
}

#Preview {
    VStack(spacing: 18) {
        UsageBar(window: UsageWindow(label: "Current session", usedPercent: 34,
                                     resetsAt: Date().addingTimeInterval(3 * 3600 + 720),
                                     kind: .session, windowSeconds: 5 * 3600))
        UsageBar(window: UsageWindow(label: "Current week (all models)", usedPercent: 82,
                                     resetsAt: Date().addingTimeInterval(5 * 86400 + 20 * 3600),
                                     kind: .weekly, windowSeconds: 7 * 86400))
        UsageBar(window: UsageWindow(label: "Current week (Fable)", usedPercent: 100,
                                     resetsAt: Date().addingTimeInterval(6 * 86400),
                                     kind: .weekly, windowSeconds: 7 * 86400))
    }
    .padding()
    .background(Term.bg)
}
