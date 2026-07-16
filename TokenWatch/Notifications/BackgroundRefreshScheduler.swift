//
//  BackgroundRefreshScheduler.swift
//  TokenWatch
//
//  BGAppRefreshTask 제출을 한곳에 모은다. 포그라운드에서 백그라운드로 나갈 때와, 매
//  백그라운드 실행 말미에 다음 실행을 재예약한다(1회성 태스크라 매번 다시 걸어야 한다).
//  실제 태스크 등록/실행은 TokenWatchApp의 .backgroundTask(.appRefresh) modifier가 맡는다.
//  (정시 리셋은 예약형 로컬 알림이 보장하고, 이 백그라운드 폴링은 "이벤트성 리셋" 감지 보조다.)
//

import Foundation
import BackgroundTasks

enum BackgroundRefreshScheduler {
    /// Info.plist의 BGTaskSchedulerPermittedIdentifiers와 반드시 일치해야 한다.
    static let taskID = "com.ScienceFiction.TokenWatch.refresh"
    /// iOS가 BGAppRefreshTask에 허용하는 실질 최소 간격(약 15분).
    static let minInterval: TimeInterval = 15 * 60

    /// 다음 백그라운드 새로고침을 제출한다.
    /// - Parameter earliestBegin: 되도록 이 시각(다음 리셋) 이후에 실행. 하한은 지금+15분.
    ///   iOS가 best-effort로 실행 시점을 자체 결정하므로 이는 "이보다 일찍은 말라"는 힌트일 뿐이다.
    static func schedule(earliestBegin: Date?) {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        let floor = Date().addingTimeInterval(minInterval)
        if let e = earliestBegin, e > floor {
            request.earliestBeginDate = e
        } else {
            request.earliestBeginDate = floor
        }
        try? BGTaskScheduler.shared.submit(request)
    }
}
