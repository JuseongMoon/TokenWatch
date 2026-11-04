//
//  PollingSupport.swift
//  TokenWatch
//
//  폴링 로그인(Copilot device flow·Cursor) 공용 부품.
//
//  사용자가 승인 페이지에서 오래 머무는 동안 앱이 백그라운드로 가면(다른 앱·Safari로 전환, 화면 잠금)
//  iOS가 앱을 멈추고, 돌아온 직후 첫 요청은 `networkConnectionLost`·DNS 실패 같은 일시 오류로 끊기기 쉽다.
//  그런 오류 한 번으로 몇 분짜리 로그인을 처음부터 다시 시키지 않도록, 폴링은 일시 네트워크 오류를
//  다음 주기로 넘기고 승인 거부·코드 만료·시간 초과로만 끝낸다. 앱이 다시 활성화되면 대기를 깨워
//  곧바로 한 번 묻는다(`PollWaker`).
//

import Foundation

nonisolated enum PollingNetwork {
    /// 요청이 서버에 닿지 못했거나 응답 전에 끊긴 일시 오류 — 다음 주기에 다시 물으면 된다.
    static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed,
             .timedOut, .cannotConnectToHost, .dataNotAllowed, .internationalRoamingOff,
             .callIsActive, .secureConnectionFailed, .backgroundSessionWasDisconnected:
            return true
        default:
            return false
        }
    }
}

/// 폴링 사이의 대기. 정해진 시간을 기다리되 `wake()`가 불리면(앱이 다시 활성화됨) 곧바로 돌아온다.
/// 대기 중이 아닐 때의 `wake()`는 버린다 — 진행 중인 요청 직후 간격을 무시하고 몰아 묻지 않게.
nonisolated final class PollWaker: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init() {}

    /// 지금 대기 중인 폴링을 깨운다.
    func wake() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            let all = Array(waiters.values)
            waiters.removeAll()
            return all
        }
        pending.forEach { $0.resume() }
    }

    /// `duration`만큼 기다리되 `wake()`되면 곧바로 돌아온다. 호출 Task가 취소되면 CancellationError.
    func sleep(for duration: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await Task.sleep(for: duration) }
            group.addTask { await self.waitForWake() }
            _ = try await group.next()
            group.cancelAll()
        }
        try Task.checkCancellation()
    }

    private func waitForWake() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let alreadyCancelled: Bool = lock.withLock {
                    if Task.isCancelled { return true }
                    waiters[id] = continuation
                    return false
                }
                if alreadyCancelled { continuation.resume() }
            }
        } onCancel: {
            let continuation = lock.withLock { waiters.removeValue(forKey: id) }
            continuation?.resume()
        }
    }
}

/// 로그인 실패 화면에 보일 문구. 앱이 정의한 오류는 그 현지화 문구를, 시스템 오류(네트워크·해석 등)는
/// 원문(`localizedDescription`) 대신 안내 문구를 쓴다 — 기기 언어의 시스템 문장이나 호스트명이 섞이지 않게.
enum LoginErrorText {
    static func message(for error: Error, lang: Lang) -> String {
        let loc = L10n(lang: lang)
        switch error {
        case is URLError:
            return loc.errLoginNetwork
        case let e as OAuthError:
            return e.errorDescription ?? loc.errLoginGeneric
        case let e as DeviceFlowError:
            return e.errorDescription ?? loc.errLoginGeneric
        case let e as UsageError:
            return e.errorDescription ?? loc.errLoginGeneric
        case let e as KimiKeyError:
            return e.errorDescription ?? loc.errLoginGeneric
        default:
            return loc.errLoginGeneric
        }
    }
}
