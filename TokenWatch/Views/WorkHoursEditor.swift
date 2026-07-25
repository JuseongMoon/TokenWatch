//
//  WorkHoursEditor.swift
//  TokenWatch
//
//  업무시간 설정 모달. 딤 배경 위에 7일 × 24시간 그리드 카드를 띄운다.
//  - 그리드는 Canvas 한 장으로 그려 168개 셀을 뷰 없이 렌더(게이지·하트와 같은 방식, 렉 없음).
//  - 탭 = 해당 블록 토글, 누른 채 드래그 = 지나가는 블록을 한 번에 칠하기(범위 선택).
//    첫 접점 블록의 상태로 "켜기/끄기" 모드를 정하고 드래그 내내 그 모드로 절대값 세팅.
//  - 저장 시에만 @AppStorage(workHoursStorageKey)에 반영. 취소/스크림 탭은 초안 폐기.
//

import SwiftUI

struct WorkHoursEditor: View {
    @Binding var isPresented: Bool

    @AppStorage(workHoursStorageKey) private var workHoursRaw = ""
    @AppStorage(appLanguageStorageKey) private var appLanguage: AppLanguage = .system
    private var loc: L10n { L10n(lang: appLanguage.resolved) }

    /// 편집 중 초안. 등장 시 저장값에서 복원하고, [저장]을 눌러야 반영된다.
    @State private var draft = WorkHoursSchedule()
    /// 현재 드래그의 칠하기 모드(true=켜기, false=끄기). 드래그 중에만 값 존재.
    @State private var paintMode: Bool?
    /// 드래그 시작 셀(슬롯 인덱스). 앵커~현재를 감싸는 사각형 전체를 칠한다.
    @State private var dragAnchor: Int?
    /// 드래그 시작 시점의 스케줄 스냅샷 — 사각형이 줄어들면 바깥 셀이 원래대로 복구되도록.
    @State private var dragBaseline: WorkHoursSchedule?

    private let gutter: CGFloat = 30    // 좌측 시간축 라벨 폭
    private let headerH: CGFloat = 24   // 상단 요일 헤더 높이

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }          // 스크림 탭 = 취소(초안 폐기)

            card
                .padding(20)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
        .onAppear { draft = WorkHoursSchedule(encoded: workHoursRaw) }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("WORK HOURS")
                    .font(.term(13, weight: .semibold))
                    .foregroundStyle(Term.cyan)
                Spacer()
                Text(loc.workHoursSummary(hours: draft.onHours))
                    .font(.term(11))
                    .foregroundStyle(draft.isEmpty ? Term.dim : Term.green)
            }

            Text(loc.workHoursEditorHelp)
                .font(.term(10))
                .foregroundStyle(Term.dim)
                .fixedSize(horizontal: false, vertical: true)

            grid
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 16) {
                Button { draft.clear() } label: {
                    Text(loc.workHoursClear).font(.term(13)).foregroundStyle(Term.dim)
                }
                .buttonStyle(.plain)
                Spacer()
                Button { close() } label: {
                    Text(loc.workHoursCancel).font(.term(13)).foregroundStyle(Term.dim)
                }
                .buttonStyle(.plain)
                Button { save() } label: {
                    Text(loc.workHoursSave).font(.term(13, weight: .semibold)).foregroundStyle(Term.green)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(Term.bg)
        .overlay(Rectangle().stroke(Term.dim, lineWidth: 1.5))
        .contentShape(Rectangle())      // 카드 내부 탭이 스크림으로 새지 않게
    }

    // MARK: 그리드(Canvas + 드래그 페인트)

    private var grid: some View {
        GeometryReader { geo in
            Canvas { ctx, size in draw(&ctx, size: size) }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in paint(at: v.location, size: geo.size) }
                        .onEnded { _ in endDrag() }
                )
        }
    }

    /// 드래그/탭 지점을 (요일,시) 셀로 역산해, 앵커~현재를 감싸는 사각형 전체를 칠한다.
    /// 대각선으로 끌어도 경로가 아니라 그 대각선을 포함하는 네모 전체가 선택된다.
    private func paint(at p: CGPoint, size: CGSize) {
        let cellW = (size.width - gutter) / CGFloat(WorkHoursSchedule.days)
        let cellH = (size.height - headerH) / CGFloat(WorkHoursSchedule.hours)
        guard cellW > 0, cellH > 0 else { return }

        // 앵커(첫 접점)는 그리드 안에서만 시작 — 라벨/헤더 영역 탭은 무시.
        if dragAnchor == nil {
            guard p.x >= gutter, p.y >= headerH else { return }
        }
        // 현재 셀 — 그리드 밖으로 나가도 경계로 클램프해 사각형 확장이 이어지게.
        let day = min(WorkHoursSchedule.days - 1, max(0, Int((p.x - gutter) / cellW)))
        let hour = min(WorkHoursSchedule.hours - 1, max(0, Int((p.y - headerH) / cellH)))

        // 첫 접점: 앵커·기준 스냅샷·칠하기 모드(켜져 있으면 끄기, 꺼져 있으면 켜기) 확정.
        if dragAnchor == nil {
            dragAnchor = WorkHoursSchedule.index(day: day, hour: hour)
            dragBaseline = draft
            paintMode = !draft.isOn(day: day, hour: hour)
        }
        guard let anchor = dragAnchor, let baseline = dragBaseline, let mode = paintMode else { return }
        let aDay = anchor / WorkHoursSchedule.hours
        let aHour = anchor % WorkHoursSchedule.hours

        // 기준 상태에서 앵커~현재를 감싸는 사각형만 mode로 덮어쓴다(바깥은 원래대로).
        draft = baseline.settingRect(from: (aDay, aHour), to: (day, hour), on: mode)
    }

    private func endDrag() {
        dragAnchor = nil
        dragBaseline = nil
        paintMode = nil
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let cellW = (size.width - gutter) / CGFloat(WorkHoursSchedule.days)
        let cellH = (size.height - headerH) / CGFloat(WorkHoursSchedule.hours)
        guard cellW > 0, cellH > 0 else { return }

        // 셀 채움.
        for day in 0..<WorkHoursSchedule.days {
            for hour in 0..<WorkHoursSchedule.hours {
                let x = gutter + CGFloat(day) * cellW
                let y = headerH + CGFloat(hour) * cellH
                let rect = CGRect(x: x, y: y, width: cellW, height: cellH).insetBy(dx: 0.5, dy: 0.5)
                let on = draft.isOn(day: day, hour: hour)
                ctx.fill(Path(rect), with: .color(on ? Term.green.opacity(0.85) : Term.track))
            }
        }

        // 격자선.
        var lines = Path()
        for day in 0...WorkHoursSchedule.days {
            let x = gutter + CGFloat(day) * cellW
            lines.move(to: CGPoint(x: x, y: headerH))
            lines.addLine(to: CGPoint(x: x, y: size.height))
        }
        for hour in 0...WorkHoursSchedule.hours {
            let y = headerH + CGFloat(hour) * cellH
            lines.move(to: CGPoint(x: gutter, y: y))
            lines.addLine(to: CGPoint(x: size.width, y: y))
        }
        ctx.stroke(lines, with: .color(Term.dim.opacity(0.35)), lineWidth: 0.5)

        // 요일 헤더.
        for day in 0..<WorkHoursSchedule.days {
            let label = ctx.resolve(Text(loc.weekdayShort(day))
                .font(.term(11, weight: .semibold))
                .foregroundStyle(Term.cyan))
            ctx.draw(label, at: CGPoint(x: gutter + (CGFloat(day) + 0.5) * cellW, y: headerH / 2))
        }

        // 시간축 라벨(3시간 간격) — 그 시각을 나타내는 가로선 옆(반 칸 위)에 정렬.
        for hour in stride(from: 0, to: WorkHoursSchedule.hours, by: 3) {
            let label = ctx.resolve(Text("\(hour)")
                .font(.term(9))
                .foregroundStyle(Term.dim))
            ctx.draw(label, at: CGPoint(x: gutter / 2, y: headerH + CGFloat(hour) * cellH))
        }
    }

    // MARK: 동작

    private func save() {
        workHoursRaw = draft.encoded
        close()
    }

    private func close() {
        endDrag()
        isPresented = false
    }
}

#Preview {
    ZStack {
        Term.bg.ignoresSafeArea()
        Text("settings behind").foregroundStyle(Term.dim)
    }
    .overlay { WorkHoursEditor(isPresented: .constant(true)) }
}
