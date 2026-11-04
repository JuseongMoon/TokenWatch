//
//  PollingLoginTests.swift
//  TokenWatchTests
//
//  폴링 로그인(Copilot device flow·Cursor) 회귀: 승인하는 동안 앱이 백그라운드로 갔다 돌아와
//  일시 네트워크 오류가 나도 로그인을 끝내지 않고, 만료·거부·시간 초과로만 끝낸다.
//  실패 화면에는 시스템 오류 원문 대신 안내 문구를 보인다.
//  대기·시계·요청은 모두 가짜를 주입한다(실제 네트워크·실제 대기 없음).
//

import Testing
import Foundation
@testable import TokenWatch

/// 테스트용 가변 상태 상자.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&_value) } }
}

@MainActor
struct PollingLoginTests {
    private let device = CopilotDeviceFlow.DeviceCode(deviceCode: "synthetic-device", userCode: "ABCD-1234",
                                                      verificationURI: nil, interval: 5, expiresIn: 900)

    /// 대기할 때마다 시계를 그만큼 앞으로 돌리는 가짜 시계·대기.
    private func fakeClock() -> (now: @Sendable () -> Date, sleep: @Sendable (Duration) async throws -> Void) {
        let clock = Box(Date(timeIntervalSince1970: 1_800_000_000))
        return ({ clock.value },
                { duration in clock.mutate { $0.addTimeInterval(TimeInterval(duration.components.seconds)) } })
    }

    // MARK: Copilot device flow

    @Test func Copilot_폴링_중_네트워크_오류_몇_번_뒤_성공하면_로그인된다() async throws {
        let (now, sleep) = fakeClock()
        let calls = Box(0)
        let errors: [URLError.Code] = [.cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed]
        let tokens = try await CopilotDeviceFlow.pollForToken(device, sleep: sleep, now: now, request: {
            calls.mutate { $0 += 1 }
            let n = calls.value
            if n <= errors.count { throw URLError(errors[n - 1]) }
            if n == errors.count + 1 { return ["error": "authorization_pending"] }
            return ["access_token": "synthetic-token"]
        })
        #expect(tokens.accessToken == "synthetic-token")
        #expect(calls.value == errors.count + 2)
    }

    @Test func Copilot_네트워크_오류만_계속되다_만료되면_만료로_실패한다() async throws {
        let (now, sleep) = fakeClock()
        let calls = Box(0)
        await #expect(throws: DeviceFlowError.self) {
            _ = try await CopilotDeviceFlow.pollForToken(device, sleep: sleep, now: now, request: {
                calls.mutate { $0 += 1 }
                throw URLError(.timedOut)
            })
        }
        do {
            _ = try await CopilotDeviceFlow.pollForToken(device, sleep: sleep, now: now, request: {
                throw URLError(.cannotConnectToHost)
            })
            Issue.record("만료로 끝나야 한다")
        } catch DeviceFlowError.expired {
            // 기대한 결과 — 네트워크 오류가 아니라 코드 만료로 끝난다.
        } catch {
            Issue.record("예상 밖 오류: \(error)")
        }
        // 900초 / 5초 간격 = 약 180번 시도한 뒤 끝난다(네트워크 오류 한 번에 끝나지 않는다).
        #expect(calls.value >= 170)
    }

    @Test func Copilot_거부와_만료_응답은_곧바로_끝낸다() async throws {
        let (now, sleep) = fakeClock()
        do {
            _ = try await CopilotDeviceFlow.pollForToken(device, sleep: sleep, now: now,
                                                         request: { ["error": "access_denied"] })
            Issue.record("거부로 끝나야 한다")
        } catch DeviceFlowError.denied {
        } catch { Issue.record("예상 밖 오류: \(error)") }

        do {
            _ = try await CopilotDeviceFlow.pollForToken(device, sleep: sleep, now: now,
                                                         request: { ["error": "expired_token"] })
            Issue.record("만료로 끝나야 한다")
        } catch DeviceFlowError.expired {
        } catch { Issue.record("예상 밖 오류: \(error)") }
    }

    @Test func 승인_직후_계정_확인은_일시_오류를_짧게_재시도한다() async throws {
        let calls = Box(0)
        let tokens = OAuthTokens(accessToken: "t", refreshToken: nil, expiresAt: nil, scopes: [],
                                 accountEmail: nil, plan: nil)
        let identified = try await CopilotDeviceFlow.identified(tokens, sleep: { _ in }, fetch: { _ in
            calls.mutate { $0 += 1 }
            if calls.value < 3 { throw URLError(.networkConnectionLost) }
            return "42"
        })
        #expect(identified.stableUserID == "42")
        #expect(calls.value == 3)
    }

    @Test func 계정_확인이_계속_실패하면_로그인을_실패로_끝낸다() async throws {
        let calls = Box(0)
        let tokens = OAuthTokens(accessToken: "t", refreshToken: nil, expiresAt: nil, scopes: [],
                                 accountEmail: nil, plan: nil)
        await #expect(throws: URLError.self) {
            _ = try await CopilotDeviceFlow.identified(tokens, sleep: { _ in }, fetch: { _ in
                calls.mutate { $0 += 1 }
                throw URLError(.cannotFindHost)
            })
        }
        #expect(calls.value == 3)

        // 일시 오류가 아닌 실패(HTTP 401 등)는 재시도하지 않는다.
        let httpCalls = Box(0)
        await #expect(throws: DeviceFlowError.self) {
            _ = try await CopilotDeviceFlow.identified(tokens, sleep: { _ in }, fetch: { _ in
                httpCalls.mutate { $0 += 1 }
                throw DeviceFlowError.http("x", code: "http_401")
            })
        }
        #expect(httpCalls.value == 1)
    }

    // MARK: Cursor

    nonisolated private static func response(_ status: Int) -> URLResponse {
        HTTPURLResponse(url: URL(string: "https://api2.cursor.sh/auth/poll")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    @Test func Cursor_폴링_중_네트워크_오류가_이어져도_승인되면_로그인된다() async throws {
        let calls = Box(0)
        let handshake = CursorAuth.makeHandshake()
        let token = try await CursorAuth.pollForAccessToken(handshake, sleep: { _ in }, send: { _ in
            calls.mutate { $0 += 1 }
            let n = calls.value
            if n <= 6 { throw URLError(n.isMultiple(of: 2) ? .dnsLookupFailed : .networkConnectionLost) }
            if n == 7 { return (Data("Not found".utf8), Self.response(404)) }
            return (Data(#"{"accessToken":"synthetic-access","refreshToken":"synthetic-refresh"}"#.utf8),
                    Self.response(200))
        })
        #expect(token == "synthetic-access")
        #expect(calls.value == 8)
    }

    @Test func Cursor_네트워크_오류만_계속되면_시도_한도에서_시간_초과로_끝난다() async throws {
        let calls = Box(0)
        let handshake = CursorAuth.makeHandshake()
        do {
            _ = try await CursorAuth.pollForAccessToken(handshake, sleep: { _ in }, send: { _ in
                calls.mutate { $0 += 1 }
                throw URLError(.notConnectedToInternet)
            })
            Issue.record("시간 초과로 끝나야 한다")
        } catch DeviceFlowError.timedOut {
        } catch {
            Issue.record("예상 밖 오류: \(error)")
        }
        #expect(calls.value == CursorAuth.maxPollAttempts)
    }

    // MARK: 포그라운드 복귀 시 즉시 폴링

    @Test func 깨우면_대기가_곧바로_끝난다() async throws {
        let waker = PollWaker()
        let started = Date()
        let sleeper = Task { try await waker.sleep(for: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        waker.wake()
        try await sleeper.value
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func 깨우지_않으면_정해진_시간만큼_기다리고_취소되면_멈춘다() async throws {
        let waker = PollWaker()
        let started = Date()
        try await waker.sleep(for: .milliseconds(200))
        #expect(Date().timeIntervalSince(started) >= 0.19)

        let cancelled = Task { try await waker.sleep(for: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    // MARK: 실패 화면 문구

    @Test func 로그인_실패_화면은_시스템_오류_원문_대신_안내_문구를_보인다() {
        for lang in [Lang.ko, Lang.en] {
            let loc = L10n(lang: lang)
            let network = LoginErrorText.message(for: URLError(.cannotFindHost), lang: lang)
            #expect(network == loc.errLoginNetwork)
            #expect(!network.contains("github.com"))
            #expect(LoginErrorText.message(for: NSError(domain: "x", code: 1), lang: lang) == loc.errLoginGeneric)
            // 앱이 정의한 오류는 기존 현지화 문구를 그대로 쓴다.
            #expect(LoginErrorText.message(for: DeviceFlowError.expired, lang: lang) == L10n(lang: currentLang()).deviceFlowExpired)
        }
        // 분석 코드는 기존 분류표 값.
        #expect(LoginFailureCode.from(URLError(.cannotFindHost)) == "network_other")
        #expect(LoginFailureCode.from(URLError(.notConnectedToInternet)) == "network_offline")
    }
}
