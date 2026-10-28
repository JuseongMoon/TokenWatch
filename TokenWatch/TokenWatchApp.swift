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
    /// 앱 계정(TokenWatch 자체 계정). provider 계정(AgentStore)과 별개다.
    @State private var account: AccountStore
    /// 몬스터 사냥·길드(V2). 계정·사용량 스토어를 읽기만 한다.
    @State private var monsters: MonsterStore

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
        // 앱 계정 — Firebase 구성 뒤에 만든다. 데모 중에는 모든 서버 호출을 막는다.
        let account = AccountStore.live(isDemo: { [weak store] in store?.isDemo ?? false })
        account.start()
        _account = State(initialValue: account)
        // 몬스터 — 새로고침 훅으로 출현을 판정하고, 계정을 지우면 그 기록을 지운다.
        let monsters = MonsterStore.live(account: account, agents: store)
        store.onRefreshed = { [weak monsters] agent, windows in await monsters?.observe(agent: agent, windows: windows) }
        account.onAccountDeleted = { [weak monsters] uid in monsters?.forgetAccount(uid: uid) }
        _monsters = State(initialValue: monsters)
        // 리뷰 프롬프트 판정용 콜드 스타트 기록.
        ReviewPromptState().recordLaunch()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(announcements)
                .environment(account)
                .environment(monsters)
                // Google 로그인 시트의 URL 콜백(다른 URL은 무시된다).
                .onOpenURL { _ = GoogleSignInFlow.handle($0) }
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
