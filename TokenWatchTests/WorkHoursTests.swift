//
//  WorkHoursTests.swift
//  TokenWatchTests
//
//  업무시간 스케줄 인코딩 + 마커 계산(WorkHours)의 순수 로직 검증.
//  - 인코딩 왕복·빈 스케줄 판정
//  - 요일 인덱스 매핑(Calendar weekday → 0=월…6=일)
//  - 구간 교집합 업무시간 합산(부분 시간 포함)
//  - 사용자 시나리오: 월 7시간 + 목 7시간 → 마커가 중간(0.5)에서 멈췄다 목요일에 1.0까지
//

import Testing
import Foundation
@testable import TokenWatch

struct WorkHoursTests {
    /// 테스트용 UTC 그레고리력 — 로컬 타임존/DST 변수를 제거한다.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ mo: Int, _ da: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: da, hour: h, minute: mi))!
    }

    /// 월(day0)·목(day3) 각각 0~7시(7시간)만 켠 스케줄.
    private func monThuMorning() -> WorkHoursSchedule {
        var s = WorkHoursSchedule()
        for hour in 0..<7 {
            s.set(day: 0, hour: hour, on: true)   // 월
            s.set(day: 3, hour: hour, on: true)   // 목
        }
        return s
    }

    // MARK: 인코딩

    @Test func encodeDecodeRoundTrip() {
        var s = WorkHoursSchedule()
        s.set(day: 2, hour: 9, on: true)
        s.set(day: 6, hour: 23, on: true)
        let restored = WorkHoursSchedule(encoded: s.encoded)
        #expect(restored == s)
        #expect(s.encoded.count == WorkHoursSchedule.slotCount)
    }

    @Test func emptyScheduleHelpers() {
        #expect(WorkHoursSchedule().isEmpty)
        #expect(WorkHoursSchedule.active(from: "") == nil)
        // 길이가 안 맞는 저장값은 빈 스케줄로 취급.
        #expect(WorkHoursSchedule(encoded: "garbage").isEmpty)
        #expect(monThuMorning().onHours == 14)
    }

    // MARK: 요일 매핑

    @Test func dayIndexMapping() {
        // Calendar weekday: 일=1, 월=2 … 토=7.  → 0=월 … 6=일.
        #expect(WorkHours.dayIndex(weekday: 2) == 0)   // 월
        #expect(WorkHours.dayIndex(weekday: 5) == 3)   // 목
        #expect(WorkHours.dayIndex(weekday: 7) == 5)   // 토
        #expect(WorkHours.dayIndex(weekday: 1) == 6)   // 일
    }

    // MARK: workingSeconds

    @Test func emptyScheduleZeroSeconds() {
        let s = WorkHoursSchedule()
        let secs = WorkHours.workingSeconds(from: date(2024, 1, 1), to: date(2024, 1, 8),
                                            schedule: s, calendar: cal)
        #expect(secs == 0)
    }

    @Test func fullScheduleEqualsWholeInterval() {
        let s = WorkHoursSchedule(slots: Array(repeating: true, count: WorkHoursSchedule.slotCount))
        let a = date(2024, 1, 1, 3, 30)
        let b = date(2024, 1, 5, 18, 15)
        let secs = WorkHours.workingSeconds(from: a, to: b, schedule: s, calendar: cal)
        #expect(abs(secs - b.timeIntervalSince(a)) < 0.5)
    }

    @Test func partialHourCounted() {
        var s = WorkHoursSchedule()
        s.set(day: 0, hour: 5, on: true)   // 월 05:00~06:00만
        // 월 05:30~06:30 → 켜진 30분(1800s)만 잡혀야.
        let secs = WorkHours.workingSeconds(from: date(2024, 1, 1, 5, 30),
                                            to: date(2024, 1, 1, 6, 30),
                                            schedule: s, calendar: cal)
        #expect(abs(secs - 1800) < 0.5)
    }

    /// 창이 요일 중간(수요일)에서 시작해도 7일 안에 각 주간 슬롯은 정확히 한 번씩 포함된다.
    @Test func totalIndependentOfWindowPhase() {
        let s = monThuMorning()
        let secs = WorkHours.workingSeconds(from: date(2024, 1, 3, 15, 0),   // 수 15:00
                                            to: date(2024, 1, 10, 15, 0),    // 다음 수 15:00
                                            schedule: s, calendar: cal)
        #expect(abs(secs - 14 * 3600) < 0.5)
    }

    // MARK: isWorkingTime — 마커 멈춤(업무시간 밖) 판정

    @Test func isWorkingTimeReflectsSlot() {
        let s = monThuMorning()   // 월·목 0~7시만
        // 월요일 03:00 → 업무시간(흐름).
        #expect(WorkHours.isWorkingTime(at: date(2024, 1, 1, 3), schedule: s, calendar: cal))
        // 월요일 09:00 → 업무시간 밖(멈춤).
        #expect(!WorkHours.isWorkingTime(at: date(2024, 1, 1, 9), schedule: s, calendar: cal))
        // 수요일 03:00 → 업무시간 밖(멈춤).
        #expect(!WorkHours.isWorkingTime(at: date(2024, 1, 3, 3), schedule: s, calendar: cal))
        // 목요일 06:00 → 업무시간(흐름).
        #expect(WorkHours.isWorkingTime(at: date(2024, 1, 4, 6), schedule: s, calendar: cal))
    }

    // MARK: 드래그 범위 선택(settingRect) — 대각선이 아니라 감싸는 사각형

    @Test func dragPaintsBoundingRectangleNotDiagonal() {
        // 앵커 (월, 9시) → 현재 (목, 12시) 대각선 드래그.
        let s = WorkHoursSchedule().settingRect(from: (day: 0, hour: 9), to: (day: 3, hour: 12), on: true)
        // 사각형 내부의 모든 셀이 켜져야(대각선만 아님). 예: (수,10시)는 대각선 경로엔 없지만 사각형엔 포함.
        for d in 0...3 {
            for h in 9...12 {
                #expect(s.isOn(day: d, hour: h))
            }
        }
        #expect(s.onHours == 4 * 4)          // 4일 × 4시간
        // 사각형 밖은 꺼진 채.
        #expect(!s.isOn(day: 4, hour: 9))    // 금요일
        #expect(!s.isOn(day: 0, hour: 8))    // 8시
        #expect(!s.isOn(day: 3, hour: 13))   // 13시
    }

    @Test func settingRectIsOrderIndependentAndCanErase() {
        // 앵커/현재 순서가 반대여도 같은 사각형.
        let a = WorkHoursSchedule().settingRect(from: (day: 3, hour: 12), to: (day: 0, hour: 9), on: true)
        let b = WorkHoursSchedule().settingRect(from: (day: 0, hour: 9), to: (day: 3, hour: 12), on: true)
        #expect(a == b)
        // 켜진 사각형 위에 on:false로 다시 칠하면 그 범위가 꺼진다(드래그로 끄기).
        let erased = a.settingRect(from: (day: 1, hour: 10), to: (day: 2, hour: 11), on: false)
        #expect(!erased.isOn(day: 1, hour: 10))
        #expect(erased.isOn(day: 0, hour: 9))   // 지운 사각형 밖은 그대로 켜짐
    }

    // MARK: markerFraction — 사용자 시나리오(월 7h + 목 7h)

    @Test func markerFreezesAndAdvancesAcrossWorkBlocks() {
        let s = monThuMorning()
        let start = date(2024, 1, 1)   // 월 00:00
        let end = date(2024, 1, 8)     // 다음 월 00:00 (정확히 7일)

        func frac(_ now: Date) -> Double? {
            WorkHours.markerFraction(windowStart: start, windowEnd: end, now: now,
                                     schedule: s, calendar: cal)
        }

        // 창 시작 = 아직 아무 업무시간도 안 흐름 → 0.
        #expect(abs((frac(date(2024, 1, 1)) ?? -1) - 0.0) < 0.001)
        // 월요일 블록 끝(07:00) → 7h/14h = 0.5.
        #expect(abs((frac(date(2024, 1, 1, 7)) ?? -1) - 0.5) < 0.001)
        // 월~목 사이(수 12:00) → 여전히 0.5로 멈춤.
        #expect(abs((frac(date(2024, 1, 3, 12)) ?? -1) - 0.5) < 0.001)
        // 목요일 블록 중간(03:30) → (7 + 3.5)/14 = 0.75.
        #expect(abs((frac(date(2024, 1, 4, 3, 30)) ?? -1) - 0.75) < 0.001)
        // 목요일 블록 끝(07:00) → 14h/14h = 1.0.
        #expect(abs((frac(date(2024, 1, 4, 7)) ?? -1) - 1.0) < 0.001)
        // 이후(토요일) → 1.0으로 고정.
        #expect(abs((frac(date(2024, 1, 6)) ?? -1) - 1.0) < 0.001)
    }

    @Test func emptyScheduleMarkerReturnsNil() {
        let s = WorkHoursSchedule()
        let f = WorkHours.markerFraction(windowStart: date(2024, 1, 1), windowEnd: date(2024, 1, 8),
                                         now: date(2024, 1, 4), schedule: s, calendar: cal)
        #expect(f == nil)
    }

    // MARK: UsageWindow 배선 — 스케줄 nil이면 기존 elapsedFraction 폴백

    @Test func usageWindowFallsBackToLinearWhenNoSchedule() {
        let now = date(2024, 1, 4)
        let win = UsageWindow(label: "week", usedPercent: 10,
                              resetsAt: date(2024, 1, 8), kind: .weekly,
                              windowSeconds: 7 * 86400)
        let marker = win.markerFraction(at: now, schedule: nil, calendar: cal)
        let linear = win.elapsedFraction(at: now)
        #expect(marker == linear)
    }
}
