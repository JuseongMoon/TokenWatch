//
//  WorkHoursSchedule.swift
//  TokenWatch
//
//  업무시간(주간 반복 스케줄) 모델 + 순수 계산.
//  주간(7일) 창의 "현재 시각" 세로선을 실제 벽시계가 아니라 "업무시간만" 흐르게 만든다.
//  - 스케줄: 7일 × 24시간 = 168개 on/off 슬롯(day 0=월 … 6=일, hour 0…23).
//  - 저장: @AppStorage에 168자 "0/1" 문자열로 인코딩(heartbeatTargets와 같은 문자열 저장 패턴).
//  - 기능 on/off는 스케줄과 분리된 별도 키(Bool?)다 — 체크를 꺼도 칠해둔 시간대는 그대로 남는다.
//  - 마커 위치 = (창시작~현재 사이 업무시간) / (창시작~창끝 사이 총 업무시간).
//    → 업무시간이 아닌 구간에선 분자가 안 늘어 마커가 그 자리에 멈춘다.
//

import Foundation

/// 업무시간 스케줄 저장 키(@AppStorage). 값은 168자 "0/1" 문자열.
let workHoursStorageKey = "tokenwatch.workHours"

/// 업무시간 기능 on/off 저장 키(@AppStorage, Bool?).
/// 키가 없으면(=토글을 한 번도 건드리지 않음) "스케줄이 있으면 켜짐"으로 해석한다 —
/// 이 토글이 없던 버전에서 올라온 사용자가 업데이트만으로 기능을 잃지 않게 하는 장치.
/// 값이 있으면 그 값이 스케줄보다 우선한다(체크를 꺼도 칠해둔 시간대는 그대로 보존).
let workHoursEnabledStorageKey = "tokenwatch.workHoursEnabled"

/// 주간 반복 업무시간 스케줄. 값 타입이라 뷰에서 매번 디코드해도 저렴하다.
struct WorkHoursSchedule: Equatable, Sendable {
    static let days = 7        // 월(0) … 일(6)
    static let hours = 24      // 0시 … 23시
    static let slotCount = days * hours   // 168

    /// index = day*24 + hour. day 0=월 … 6=일.
    private(set) var slots: [Bool]

    init() { slots = Array(repeating: false, count: Self.slotCount) }

    init(slots: [Bool]) {
        self.slots = slots.count == Self.slotCount
            ? slots
            : Array(repeating: false, count: Self.slotCount)
    }

    static func index(day: Int, hour: Int) -> Int { day * hours + hour }

    func isOn(day: Int, hour: Int) -> Bool {
        guard day >= 0, day < Self.days, hour >= 0, hour < Self.hours else { return false }
        return slots[Self.index(day: day, hour: hour)]
    }

    mutating func set(day: Int, hour: Int, on: Bool) {
        guard day >= 0, day < Self.days, hour >= 0, hour < Self.hours else { return }
        slots[Self.index(day: day, hour: hour)] = on
    }

    mutating func clear() { slots = Array(repeating: false, count: Self.slotCount) }

    /// 두 셀(앵커·현재)을 감싸는 사각형 전체를 on으로 덮어쓴 새 스케줄.
    /// 드래그 범위 선택용 — 대각선으로 끌어도 경로가 아니라 그 대각선을 포함하는 네모가 칠해진다.
    /// (뷰 밖 순수 함수 — 좌표 역산과 분리해 단위 테스트로 고정한다.)
    func settingRect(from a: (day: Int, hour: Int), to b: (day: Int, hour: Int), on: Bool) -> WorkHoursSchedule {
        var next = self
        let dLo = max(0, min(a.day, b.day)), dHi = min(Self.days - 1, max(a.day, b.day))
        let hLo = max(0, min(a.hour, b.hour)), hHi = min(Self.hours - 1, max(a.hour, b.hour))
        guard dLo <= dHi, hLo <= hHi else { return next }
        for d in dLo...dHi {
            for h in hLo...hHi {
                next.set(day: d, hour: h, on: on)
            }
        }
        return next
    }

    /// 켜진 슬롯이 하나도 없으면 true. on/off 토글과는 별개로, 스케줄이 비면
    /// 흐름을 바꿀 근거가 없어 호출부가 균일 흐름으로 폴백한다.
    var isEmpty: Bool { !slots.contains(true) }

    /// 켜진 슬롯(=시간) 개수. 각 슬롯이 정확히 1시간이므로 "주 N시간"의 N.
    var onHours: Int { slots.lazy.filter { $0 }.count }

    // MARK: 인코딩(@AppStorage 문자열)

    /// 168자 "0/1" 문자열.
    var encoded: String { String(slots.map { $0 ? "1" : "0" }) }

    /// 168자 "0/1" 문자열에서 복원. 길이가 다르면 빈 스케줄.
    init(encoded: String) {
        let chars = Array(encoded)
        slots = chars.count == Self.slotCount
            ? chars.map { $0 == "1" }
            : Array(repeating: false, count: Self.slotCount)
    }

    /// 명시 설정(nil=미설정)과 저장된 스케줄에서 기능 on/off를 확정한다.
    /// 순수 함수 — 뷰(@AppStorage)와 AnalyticsService(UserDefaults)가 같은 규칙을 공유한다.
    static func isEnabled(explicit: Bool?, raw: String) -> Bool {
        explicit ?? !WorkHoursSchedule(encoded: raw).isEmpty
    }

    /// UserDefaults에서 직접 읽는 편의 오버로드(뷰 밖 호출부용. 테스트는 store를 주입한다).
    static func isEnabled(in d: UserDefaults = .standard) -> Bool {
        isEnabled(explicit: d.object(forKey: workHoursEnabledStorageKey) as? Bool,
                  raw: d.string(forKey: workHoursStorageKey) ?? "")
    }

    /// @AppStorage 원문에서 디코드하되, 기능이 꺼져 있거나 비어있으면
    /// nil(기능 꺼짐 신호 — 호출부는 균일 흐름으로 폴백)로 돌려준다.
    /// `enabled`에 기본값을 두지 않는다 — 호출부 누락을 컴파일러가 전부 잡아내게 하려는 의도.
    static func active(from raw: String, enabled: Bool?) -> WorkHoursSchedule? {
        guard isEnabled(explicit: enabled, raw: raw) else { return nil }
        let s = WorkHoursSchedule(encoded: raw)
        return s.isEmpty ? nil : s
    }
}

/// 업무시간 마커 계산(뷰 밖 순수 함수 — 단위 테스트로 고정한다).
enum WorkHours {
    /// Calendar의 weekday(1=일 … 7=토)를 스케줄 인덱스(0=월 … 6=일)로 변환.
    /// 월(2)→0, 화(3)→1, … 토(7)→5, 일(1)→6.
    static func dayIndex(weekday: Int) -> Int { (weekday + 5) % 7 }

    /// 주어진 시각이 켜진(업무) 슬롯 안인지. 마커 "멈춤"(업무시간 밖) 판정에 쓴다.
    static func isWorkingTime(at now: Date, schedule: WorkHoursSchedule,
                             calendar: Calendar = .current) -> Bool {
        let comps = calendar.dateComponents([.weekday, .hour], from: now)
        let day = dayIndex(weekday: comps.weekday ?? 1)
        let hour = comps.hour ?? 0
        return schedule.isOn(day: day, hour: hour)
    }

    /// [start, end] 구간에서 켜진(업무) 슬롯과 겹치는 총 시간(초).
    /// 시(hour) 경계를 걸어가며 부분 시간까지 정확히 합산한다(최대 ~169회 반복, DST 안전).
    static func workingSeconds(from start: Date, to end: Date,
                               schedule: WorkHoursSchedule,
                               calendar: Calendar) -> TimeInterval {
        guard end > start, !schedule.isEmpty else { return 0 }
        var total: TimeInterval = 0
        var cursor = start
        // 안전장치: 창 최대 7일 → 200회면 충분. 무한 루프 방지용 상한.
        var guardCount = 0
        while cursor < end && guardCount < 400 {
            guardCount += 1
            let comps = calendar.dateComponents([.weekday, .hour], from: cursor)
            let day = dayIndex(weekday: comps.weekday ?? 1)
            let hour = comps.hour ?? 0
            // 현재 시각이 속한 시(hour)의 다음 정각(엄격히 이후).
            let nextHour = calendar.nextDate(after: cursor,
                                             matching: DateComponents(minute: 0, second: 0),
                                             matchingPolicy: .nextTime)
                ?? cursor.addingTimeInterval(3600)
            let segmentEnd = min(nextHour, end)
            if segmentEnd <= cursor { break }   // 방어적 — 이론상 항상 cursor보다 큼
            if schedule.isOn(day: day, hour: hour) {
                total += segmentEnd.timeIntervalSince(cursor)
            }
            cursor = segmentEnd
        }
        return total
    }

    /// 업무시간 기준 마커 위치(0…1). 총 업무시간이 0이면 nil(호출부가 균일 흐름으로 폴백).
    static func markerFraction(windowStart: Date, windowEnd: Date, now: Date,
                               schedule: WorkHoursSchedule,
                               calendar: Calendar) -> Double? {
        guard windowEnd > windowStart else { return nil }
        let total = workingSeconds(from: windowStart, to: windowEnd,
                                   schedule: schedule, calendar: calendar)
        guard total > 0 else { return nil }
        let clampedNow = min(max(now, windowStart), windowEnd)
        let done = workingSeconds(from: windowStart, to: clampedNow,
                                  schedule: schedule, calendar: calendar)
        return min(1, max(0, done / total))
    }
}
