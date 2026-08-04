//
//  RetryAfterTests.swift
//  TokenWatchTests
//
//  parseRetryAfter의 방어 로직 검증: `Double(String)`이 성공 파싱하는 비정상 값
//  ("inf"·"1e400" 등)이 무한대 Date가 되어 백오프 표시의 `Int(...)` 변환에서
//  트랩하지 않아야 한다 — 유한·비음수·상한(24시간) 불변식을 확인한다.
//

import Testing
import Foundation
@testable import TokenWatch

struct RetryAfterTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let maxRetryAfter: TimeInterval = 24 * 60 * 60

    // MARK: 정상 값

    @Test func plainSecondsParses() {
        let date = parseRetryAfter("120", now: now)
        #expect(date == now.addingTimeInterval(120))
    }

    @Test func zeroSecondsParses() {
        #expect(parseRetryAfter("0", now: now) == now)
    }

    @Test func httpDateParses() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let target = now.addingTimeInterval(600)
        let date = parseRetryAfter(f.string(from: target), now: now)
        #expect(date != nil)
        // 포맷 왕복은 초 단위라 1초 오차 허용.
        #expect(abs(date!.timeIntervalSince(target)) < 1)
    }

    // MARK: 비정상 값 — 버려야 함

    @Test(arguments: ["inf", "infinity", "+inf", "nan", "-1", "-120", "garbage", ""])
    func invalidValuesReturnNil(_ value: String) {
        #expect(parseRetryAfter(value, now: now) == nil)
    }

    @Test func nilReturnsNil() {
        #expect(parseRetryAfter(nil, now: now) == nil)
    }

    // MARK: 과대 값 — 상한으로 클램프

    @Test(arguments: ["1e400", "99999999999999999999", "9223372036854775807"])
    func hugeSecondsClampToMax(_ value: String) {
        guard let date = parseRetryAfter(value, now: now) else {
            // "1e400"은 무한대라 nil이어도 안전(불변식 위반 아님).
            return
        }
        #expect(date.timeIntervalSince(now) <= maxRetryAfter)
    }

    @Test func farFutureHTTPDateClampsToMax() {
        let date = parseRetryAfter("Fri, 01 Jan 2100 00:00:00 GMT", now: now)
        #expect(date != nil)
        #expect(date!.timeIntervalSince(now) <= maxRetryAfter)
    }

    // MARK: 크래시 재현 경로의 불변식

    /// rateLimitedSnapshot의 `Int(until.timeIntervalSinceNow)`가 트랩하지 않으려면
    /// 결과가 항상 유한하고 Int 범위 안이어야 한다.
    @Test(arguments: ["120", "inf", "1e400", "99999999999999999999",
                      "Fri, 01 Jan 2100 00:00:00 GMT"])
    func resultIsAlwaysSafeForIntConversion(_ value: String) {
        guard let date = parseRetryAfter(value, now: now) else { return }
        let interval = date.timeIntervalSince(now)
        #expect(interval.isFinite)
        #expect(interval <= maxRetryAfter)
        _ = Int(interval)   // 트랩하면 테스트가 크래시로 실패한다.
    }
}
