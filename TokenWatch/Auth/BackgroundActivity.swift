//
//  BackgroundActivity.swift
//  TokenWatch
//
//  짧은 실행 유예(UIApplication background task) 래퍼.
//
//  토큰 갱신처럼 "중간에 끊기면 상태가 깨지는" 왕복에만 쓴다. 앱이 백그라운드로
//  나가는 순간 URLSession 왕복이 잘리면 서버는 refresh token을 로테이션했는데
//  우리는 새 토큰을 못 받는 상황이 생긴다(= 자격증명 영구 사망).
//

import UIKit

@MainActor
enum BackgroundActivity {
    /// 아직 end되지 않은 식별자. 만료 핸들러와 정상 종료가 이중으로 end하지 않게 한다.
    private static var live: Set<Int> = []

    /// 만료 핸들러가 자기 식별자를 되잡을 수 있게 하는 상자(핸들러 등록 시점엔 아직 값이 없다).
    private final class Box: @unchecked Sendable {
        var id: UIBackgroundTaskIdentifier = .invalid
    }

    static func begin(name: String) -> UIBackgroundTaskIdentifier {
        let box = Box()
        box.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            // 유예 시간이 끝나면 반드시 종료해야 한다(안 하면 시스템이 앱을 죽인다).
            MainActor.assumeIsolated { end(box.id) }
        }
        if box.id != .invalid { live.insert(box.id.rawValue) }
        return box.id
    }

    static func end(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid, live.remove(id.rawValue) != nil else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
}
