//
//  TokenWatchApp.swift
//  TokenWatch
//
//  Created by 문주성 on 7/9/26.
//

import SwiftUI

@main
struct TokenWatchApp: App {
    @State private var store: AgentStore
    /// 서버 공지 팝업 상태. 사용량 스토어와 분리해 두 경로가 서로 영향을 주지 않는다.
    @State private var announcements = AnnouncementStore()

    init() {
        // Firebase는 스토어 생성보다 먼저 구성한다(시작 시 유저 속성 동기화가 곧바로 반영되도록).
        AnalyticsService.shared.configure()
        // 포그라운드에서도 알림 배너를 표시하도록 delegate를 등록한다.
        NotificationManager.shared.configure()
        let store = AgentStore()
        _store = State(initialValue: store)
        // 데모 판별 주입 + 시작 시 유저 속성 1회 동기화(드리프트 방지).
        AnalyticsService.shared.isDemo = { [weak store] in store?.isDemo ?? false }
        AnalyticsService.shared.syncUserProperties(agents: store.agents)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(announcements)
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
