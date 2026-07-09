//
//  TokenWatchTests.swift
//  TokenWatchTests
//
//  Created by 문주성 on 7/9/26.
//

import Testing
import Foundation
@testable import TokenWatch

struct TokenWatchTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// 노란선 위치: 5시간 창에서 2.5시간 남으면 정중앙(0.5), 1시간 남으면 4/5(0.8).
    @Test func elapsedFractionMatchesTimeLeft() {
        let half = UsageWindow(label: "s", usedPercent: 0,
                               resetsAt: now.addingTimeInterval(2.5 * 3600),
                               kind: .session, windowSeconds: 5 * 3600)
        #expect(abs((half.elapsedFraction(at: now) ?? -1) - 0.5) < 0.0001)

        let fourFifths = UsageWindow(label: "s", usedPercent: 0,
                                     resetsAt: now.addingTimeInterval(1 * 3600),
                                     kind: .session, windowSeconds: 5 * 3600)
        #expect(abs((fourFifths.elapsedFraction(at: now) ?? -1) - 0.8) < 0.0001)
    }

    /// 경계: 리셋이 지났으면 1.0으로 클램프, 주기 정보가 없으면 nil.
    @Test func elapsedFractionClampsAndGuards() {
        let past = UsageWindow(label: "s", usedPercent: 0,
                               resetsAt: now.addingTimeInterval(-100),
                               kind: .session, windowSeconds: 5 * 3600)
        #expect(past.elapsedFraction(at: now) == 1.0)

        let noDuration = UsageWindow(label: "s", usedPercent: 0,
                                     resetsAt: now.addingTimeInterval(3600), kind: .session)
        #expect(noDuration.elapsedFraction(at: now) == nil)
    }

    /// 페이스: 절반(2.5h 남음) 경과에 80% 사용이면 시간 대비 +30%p 빠름.
    @Test func paceDeltaReflectsOverspend() {
        let w = UsageWindow(label: "s", usedPercent: 80,
                            resetsAt: now.addingTimeInterval(2.5 * 3600),
                            kind: .session, windowSeconds: 5 * 3600)
        #expect(abs((w.paceDelta(at: now) ?? 0) - 30) < 0.0001)
    }

    /// Claude 창은 종류별 기본 주기가 채워진다(세션 18000초, 주간 604800초).
    @Test func windowKindDefaultSeconds() {
        #expect(WindowKind.session.defaultSeconds == 18_000)
        #expect(WindowKind.weekly.defaultSeconds == 604_800)
    }

    /// 실제 /usage 응답: 새 `limits` 배열이 session/weekly_all/weekly_scoped(Fable)
    /// 3창으로 매핑된다. (Fable은 percent 0, resets_at null)
    @Test func claudeLimitsMapThreeWindows() throws {
        let json = Data("""
        {"five_hour":{"utilization":58.0,"resets_at":"2026-07-09T14:49:59.739913+00:00"},
         "seven_day":{"utilization":36.0,"resets_at":"2026-07-14T22:59:59.739941+00:00"},
         "seven_day_opus":null,"seven_day_sonnet":null,"tangelo":null,
         "extra_usage":{"is_enabled":false,"utilization":100.0},
         "limits":[
           {"kind":"session","group":"session","percent":58,"resets_at":"2026-07-09T14:49:59.739913+00:00","scope":null,"is_active":true},
           {"kind":"weekly_all","group":"weekly","percent":36,"resets_at":"2026-07-14T22:59:59.739941+00:00","scope":null,"is_active":false},
           {"kind":"weekly_scoped","group":"weekly","percent":0,"resets_at":null,"scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}
         ]}
        """.utf8)
        let resp = try JSONDecoder().decode(ClaudeUsageResponse.self, from: json)
        let windows = ClaudeUsageMapper.windows(from: resp)
        #expect(windows.count == 3)
        #expect(windows[0].label == "Current session")
        #expect(windows[0].usedPercent == 58)
        #expect(windows[1].label == "Current week (all models)")
        #expect(windows[1].usedPercent == 36)
        #expect(windows[2].label == "Current week (Fable)")
        #expect(windows[2].usedPercent == 0)
        #expect(windows[2].resetsAt == nil)
    }

    /// 구형 응답(limits 없음)은 five_hour/seven_day fallback으로 매핑된다.
    @Test func claudeLegacyKeysFallback() throws {
        let json = Data("""
        {"five_hour":{"utilization":58.0,"resets_at":"2026-07-09T14:49:59.739913+00:00"},
         "seven_day":{"utilization":36.0,"resets_at":"2026-07-14T22:59:59.739941+00:00"}}
        """.utf8)
        let resp = try JSONDecoder().decode(ClaudeUsageResponse.self, from: json)
        let windows = ClaudeUsageMapper.windows(from: resp)
        #expect(windows.count == 2)
        #expect(windows[0].label == "Current session")
        #expect(windows[1].label == "Current week (all models)")
    }
}
