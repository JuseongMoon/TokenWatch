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

    @AppStorage(appLanguageStorageKey) private var appLanguage: AppLanguage = .system
    /// 업무시간 스케줄(주간 마커용).
    @AppStorage(workHoursStorageKey) private var workHoursRaw = ""
    /// 업무시간 기능 on/off. 키 부재(nil)면 스케줄 유무로 판단 — 구버전 사용자 보존.
    @AppStorage(workHoursEnabledStorageKey) private var workHoursEnabled: Bool?
    private var loc: L10n { L10n(lang: appLanguage.resolved) }

    private var usedFraction: Double { max(0, min(1, window.usedPercent / 100)) }
    private var statusColor: Color { Term.statusColor(remainingPercent: window.remainingPercent) }

    /// 마커에 실제로 쓸 스케줄. 기능이 꺼졌거나 비어 있으면 nil → 균일 흐름.
    private var activeSchedule: WorkHoursSchedule? {
        WorkHoursSchedule.active(from: workHoursRaw, enabled: workHoursEnabled)
    }

    /// 주간 창의 마커 위치. 업무시간이 켜져 있으면 그 시간에만 흐르고, 꺼졌거나 세션 창이면 실시간 균일.
    private func markerFraction(at now: Date) -> Double? {
        guard window.kind == .weekly else { return window.elapsedFraction(at: now) }
        return window.markerFraction(at: now, schedule: activeSchedule)
    }

    /// 마커가 "멈춤"(업무시간 밖) 상태인지 — 주간 창 + 업무시간 활성 + 지금이 업무시간 밖일 때만.
    private func markerPaused(at now: Date) -> Bool {
        guard window.kind == .weekly, let schedule = activeSchedule else { return false }
        return !WorkHours.isWorkingTime(at: now, schedule: schedule)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(window.label.uppercased())
                .font(.term(11, weight: .semibold))
                .foregroundStyle(Term.cyan)

            switch window.style {
            case .gauge:       gauge
            case .creditGauge: creditGauge
            case .balance:     balanceValue
            }

            if window.resetsAt != nil {
                Text(window.resetSummary(loc))
                    .font(.term(10))
                    .foregroundStyle(Term.dim)
            }
        }
    }

    // 게이지 스타일(한도 있는 사용률).
    private var gauge: some View {
        // TimelineView로 네트워크 갱신과 무관하게 마커(현재 시각)가 흐르게 한다.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 8) {
                // 반응형: 남은 가로폭을 게이지가 최대한 채운다.
                TerminalGauge(usedFraction: usedFraction,
                              fillColor: statusColor,
                              elapsedFraction: markerFraction(at: context.date),
                              markerPaused: markerPaused(at: context.date),
                              height: 14, bracketSize: 13,
                              critterVariant: GaugeCritterVariant(kind: window.kind))
                // 퍼센트는 오른쪽 고정 — 3자리(100%)까지 자리를 확보해 바 길이가 흔들리지 않게.
                Text("\(String(format: "%3d", Int(window.usedPercent.rounded())))% used")
                    .font(.term(12))
                    .monospacedDigit()
                    .foregroundStyle(statusColor)
                    .fixedSize()
            }
        }
    }

    // 충전형 잔액 게이지(채움=남은 잔액, 역방향) + 잔액 텍스트 병기.
    private var creditGauge: some View {
        HStack(spacing: 8) {
            TerminalGauge(usedFraction: usedFraction,
                          fillColor: statusColor,
                          elapsedFraction: nil,
                          fillsRemaining: true,
                          height: 14, bracketSize: 13,
                          critterVariant: GaugeCritterVariant(kind: window.kind))
            Text(balanceText)
                .font(.term(12))
                .foregroundStyle(statusColor)
                .fixedSize()
        }
    }

    /// 잔액 텍스트(추정 게이지면 ~ 접두로 부정확함을 표시).
    private var balanceText: String {
        let base = window.valueText ?? "—"
        return window.estimatedTotal ? "~\(base)" : base
    }

    // 잔액 스타일(한도 없는 선불 크레딧 — 절대값 텍스트).
    private var balanceValue: some View {
        HStack(spacing: 6) {
            Text("▸").foregroundStyle(Term.dim)
            Text(window.valueText ?? "—")
                .font(.term(15, weight: .semibold))
                .foregroundStyle(Term.green)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
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
        UsageBar(window: UsageWindow(label: "Credits", usedPercent: 0, resetsAt: nil,
                                     kind: .weekly, style: .balance, valueText: "6.50 USD left"))
        // 충전형 게이지(역방향): 정확(API 총액) + 추정(peak, ~ 접두).
        UsageBar(window: UsageWindow(label: "Credits", usedPercent: 2.5, resetsAt: nil,
                                     kind: .weekly, style: .creditGauge,
                                     valueText: "487.50 credits left",
                                     balanceRemaining: 487.5, balanceTotal: 500))
        UsageBar(window: UsageWindow(label: "Balance", usedPercent: 82, resetsAt: nil,
                                     kind: .weekly, style: .creditGauge,
                                     valueText: "18.00 USD", balanceRemaining: 18,
                                     estimatedTotal: true))
        // 잔액 소진: 빈 트랙 위에서 슬라임이 논다(역방향 소진).
        UsageBar(window: UsageWindow(label: "Balance", usedPercent: 99.7, resetsAt: nil,
                                     kind: .weekly, style: .creditGauge,
                                     valueText: "1.50 credits left",
                                     balanceRemaining: 1.5, balanceTotal: 500))
    }
    .padding()
    .background(Term.bg)
}
