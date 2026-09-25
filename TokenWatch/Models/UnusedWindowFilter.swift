//
//  UnusedWindowFilter.swift
//  TokenWatch
//
//  "hide unused graphs" 설정(퍼센테이지 / 충전식)의 저장 키와 목록·상세 공통 필터.
//

import Foundation

nonisolated enum UnusedWindowFilter {
    /// 사용률 0% 구독 게이지 숨김. 단일 설정이던 시절의 키를 그대로 써서 기존 사용자 선택을 보존한다.
    static let hidePercentKey = "tokenwatch.hideUnusedWindows"
    /// 한 번도 쓰지 않은 충전식 게이지(총액을 아는 것만) 숨김.
    static let hideCreditKey = "tokenwatch.hideUnusedCredits"

    /// 설정에 따라 숨길 창을 뺀 목록. 순서는 유지한다.
    static func visible(_ windows: [UsageWindow], hidePercent: Bool, hideCredit: Bool) -> [UsageWindow] {
        guard hidePercent || hideCredit else { return windows }
        return windows.filter { w in
            !(hidePercent && w.isUnused) && !(hideCredit && w.isUnusedCredit)
        }
    }
}
