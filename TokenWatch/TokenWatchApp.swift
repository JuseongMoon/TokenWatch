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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .preferredColorScheme(.dark)   // 블랙 단일 테마 고정
                .tint(Term.green)
        }
    }
}
