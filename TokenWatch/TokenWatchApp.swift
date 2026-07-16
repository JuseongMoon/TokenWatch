//
//  TokenWatchApp.swift
//  TokenWatch
//
//  Created by 문주성 on 7/9/26.
//

import SwiftUI

@main
struct TokenWatchApp: App {
    @State private var store = AgentStore()

    init() {
        // 포그라운드에서도 알림 배너를 표시하도록 delegate를 등록한다.
        NotificationManager.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .preferredColorScheme(.dark)   // 블랙 단일 테마 고정
                .tint(Term.green)
        }
        // 백그라운드에서 깨어나면 갱신(리셋 감지·알림은 refresh 훅이 처리)하고 다음 실행을 재예약한다.
        .backgroundTask(.appRefresh(BackgroundRefreshScheduler.taskID)) {
            await store.performBackgroundRefresh()
            let next = await store.nextResetDate()
            BackgroundRefreshScheduler.schedule(earliestBegin: next)
        }
    }
}
