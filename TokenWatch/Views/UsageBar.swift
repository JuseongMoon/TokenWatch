//
//  UsageBar.swift
//  TokenWatch
//
//  원래 Claude Code `/usage` 화면처럼 가로 막대그래프로 사용량을 표시한다.
//  제목 → 바(used만큼 채움) + "N% used" → 리셋 텍스트(정확한 시각 + 남은 시간).
//

import SwiftUI

struct UsageBar: View {
    let window: UsageWindow

    private var usedFraction: Double { max(0, min(1, window.usedPercent / 100)) }

    /// 잔여량 기준 색: 여유=파랑, 부족=주황/빨강.
    private var fillColor: Color {
        switch window.remainingPercent {
        case ..<10: return .red
        case ..<25: return .orange
        default: return Color.accentColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(window.label)
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 10) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.22))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(fillColor)
                            .frame(width: max(0, geo.size.width * usedFraction))
                            .animation(.easeOut(duration: 0.4), value: usedFraction)
                    }
                }
                .frame(height: 14)

                Text("\(Int(window.usedPercent.rounded()))% used")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            if let resetsAt = window.resetsAt {
                Text(resetText(resetsAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: 리셋 텍스트

    private func resetText(_ date: Date) -> String {
        if date <= Date() { return "리셋됨" }
        return "리셋 \(exactString(date)) · \(remainingString(date))"
    }

    /// 정확한 리셋 시각. 세션은 시각만, 주간은 날짜+시각.
    private func exactString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        switch window.kind {
        case .session:
            f.dateFormat = "a h:mm"
        case .weekly:
            f.dateFormat = "M월 d일 a h:mm"
        }
        return f.string(from: date)
    }

    /// 남은 시간. 세션은 시·분, 주간은 일·시간.
    private func remainingString(_ date: Date) -> String {
        let now = Date()
        switch window.kind {
        case .session:
            let c = Calendar.current.dateComponents([.hour, .minute], from: now, to: date)
            let h = max(0, c.hour ?? 0), m = max(0, c.minute ?? 0)
            if h > 0 { return "\(h)시간 \(m)분 남음" }
            return "\(m)분 남음"
        case .weekly:
            let c = Calendar.current.dateComponents([.day, .hour], from: now, to: date)
            let d = max(0, c.day ?? 0), h = max(0, c.hour ?? 0)
            if d > 0 { return "\(d)일 \(h)시간 남음" }
            return "\(h)시간 남음"
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        UsageBar(window: UsageWindow(label: "Current session", usedPercent: 34,
                                     resetsAt: Date().addingTimeInterval(3 * 3600 + 720), kind: .session))
        UsageBar(window: UsageWindow(label: "Current week (all models)", usedPercent: 26,
                                     resetsAt: Date().addingTimeInterval(5 * 86400 + 20 * 3600), kind: .weekly))
        UsageBar(window: UsageWindow(label: "Current week (Fable)", usedPercent: 0,
                                     resetsAt: Date().addingTimeInterval(6 * 86400), kind: .weekly))
    }
    .padding()
}
