//
//  APIKeyRejectedTests.swift
//  TokenWatchTests
//
//  API 키 서비스가 키를 거부(HTTP 401)했을 때의 카드 문구 검증:
//  Kimi·DeepSeek·Poe·ElevenLabs는 서비스 이름을 넣은 공통 안내, OpenRouter는 관리 키 안내.
//  분석 분류는 바꾸기 전과 같고(401 → auth), 401이 아닌 응답(403·429·5xx·네트워크)은 기존 처리 그대로다.
//  상태 코드 → 오류 순수 함수만 부른다(네트워크 없음).
//

import Testing
import Foundation
@testable import TokenWatch

@MainActor
struct APIKeyRejectedTests {
    private var loc: L10n { L10n(lang: currentLang()) }

    /// 상태 코드 → 오류(공통 안내를 쓰는 서비스 중 상태 코드 함수가 있는 셋).
    private func statusError(_ provider: AgentProvider, _ status: Int,
                             retryAfter: String? = nil, body: Data = Data()) -> UsageError? {
        switch provider {
        case .deepseek: return DeepSeekUsageClient.statusError(status, retryAfter: retryAfter, body: body)
        case .poe: return PoeUsageClient.statusError(status, retryAfter: retryAfter, body: body)
        case .elevenlabs: return ElevenLabsUsageClient.statusError(status, retryAfter: retryAfter, body: body)
        default:
            Issue.record("상태 코드 함수가 없는 provider: \(provider.rawValue)")
            return nil
        }
    }

    // MARK: 401 → 서비스 이름을 넣은 안내

    @Test(arguments: [AgentProvider.deepseek, .poe, .elevenlabs])
    func 키_서비스의_401은_서비스_이름을_넣은_키_거부_안내가_된다(_ provider: AgentProvider) {
        let error = statusError(provider, 401)
        guard case .keyRejected(401, let message)? = error else {
            Issue.record("401 분류 실패: \(provider.rawValue)"); return
        }
        #expect(message == loc.errAPIKeyRejected(provider.displayName))
        #expect(message.contains(provider.displayName))
        #expect(error?.errorDescription == message)
    }

    @Test(arguments: [AgentProvider.deepseek, .poe, .elevenlabs])
    func 키_거부의_분석_분류는_바꾸기_전과_같다(_ provider: AgentProvider) throws {
        let error = try #require(statusError(provider, 401))
        // 바꾸기 전에는 401 → unauthorized → 강제 갱신 → notAuthenticated로 끝나 `auth`였다.
        #expect(FetchErrorReason(classifying: error) == .auth)
        #expect(FetchErrorReason(classifying: error) == FetchErrorReason(classifying: OAuthError.notAuthenticated))
        #expect(LoginFailureCode.from(error) == LoginFailureCode.from(UsageError.unauthorized))
        // API 키에는 refresh가 없다 — 강제 갱신 경로(`unauthorized`)로 보내지 않는다.
        if case .unauthorized = error { Issue.record("401이 강제 갱신 경로로 가면 안 된다") }
    }

    @Test(arguments: [AgentProvider.deepseek, .poe, .elevenlabs])
    func 키_서비스의_429_5xx_2xx는_기존_처리를_유지한다(_ provider: AgentProvider) {
        guard case .rateLimited? = statusError(provider, 429, retryAfter: "30") else {
            Issue.record("429: \(provider.rawValue)"); return
        }
        guard case .http(502, _)? = statusError(provider, 502) else {
            Issue.record("5xx: \(provider.rawValue)"); return
        }
        #expect(statusError(provider, 200) == nil)
    }

    // MARK: 401이 아닌 응답은 키 거부로 바꾸지 않는다

    @Test func Poe_403은_키_거부가_아니라_기존_처리_그대로다() {
        // 문서상 403은 권한·인가 문제(키 무효 아님).
        guard case .unauthorized? = PoeUsageClient.statusError(403, retryAfter: nil, body: Data()) else {
            Issue.record("Poe 403"); return
        }
    }

    @Test func ElevenLabs_403은_키_거부가_아니라_HTTP_오류_그대로다() {
        // 문서상 403은 키의 IP 허용 목록 밖에서 온 요청.
        guard case .http(403, _)? = ElevenLabsUsageClient.statusError(403, retryAfter: nil, body: Data()) else {
            Issue.record("ElevenLabs 403"); return
        }
    }

    @Test func DeepSeek_402_잔액_부족은_키_거부가_아니다() {
        guard case .http(402, _)? = DeepSeekUsageClient.statusError(402, retryAfter: nil, body: Data()) else {
            Issue.record("DeepSeek 402"); return
        }
    }

    // MARK: Kimi — 카드 조회만 바꾸고 추가 전 확인 흐름은 그대로

    @Test func Kimi_카드_조회의_401은_키_거부_안내가_된다() {
        let error = KimiUsageClient.cardError(UsageError.unauthorized)
        guard case .keyRejected(401, let message)? = error as? UsageError else {
            Issue.record("Kimi 401 분류 실패"); return
        }
        #expect(message == loc.errAPIKeyRejected(AgentProvider.kimi.displayName))
        #expect(FetchErrorReason(classifying: error) == .auth)
        #expect(LoginFailureCode.from(error) == "http_401")
    }

    @Test func Kimi_카드_조회의_다른_오류는_그대로_둔다() {
        guard case .rateLimited? = KimiUsageClient.cardError(UsageError.rateLimited(nil)) as? UsageError else {
            Issue.record("429"); return
        }
        guard case .http(404, _)? = KimiUsageClient.cardError(UsageError.http(404, "")) as? UsageError else {
            Issue.record("404"); return
        }
        #expect((KimiUsageClient.cardError(URLError(.notConnectedToInternet)) as? URLError)?.code
                == .notConnectedToInternet)
        #expect(KimiUsageClient.cardError(CancellationError()) is CancellationError)
    }

    // MARK: OpenRouter

    @Test func OpenRouter_401은_새_문구로_403은_관리_키_안내_그대로다() {
        guard case .keyRejected(401, let message401)? = OpenRouterUsageClient.statusError(401, retryAfter: nil,
                                                                                          body: Data()) else {
            Issue.record("OpenRouter 401"); return
        }
        #expect(message401 == loc.errOpenRouterKeyRejected)
        #expect(FetchErrorReason(classifying: UsageError.keyRejected(status: 401, message: message401)) == .auth)

        guard case .keyRejected(403, let message403)? = OpenRouterUsageClient.statusError(403, retryAfter: nil,
                                                                                          body: Data()) else {
            Issue.record("OpenRouter 403"); return
        }
        #expect(message403 == loc.errOpenRouterNeedsManagementKey)
        #expect(FetchErrorReason(classifying: UsageError.keyRejected(status: 403, message: message403)) == .http4xx)
    }

    // MARK: 문구(Android와 같은 문장)

    @Test func 키_거부_문구는_정한_문장_그대로다() {
        let ko = L10n(lang: .ko), en = L10n(lang: .en)
        #expect(ko.errAPIKeyRejected("DeepSeek")
                == "DeepSeek에서 키를 거부했습니다(HTTP 401). 키가 만료되거나 삭제되지 않았는지 확인한 뒤, 이 카드를 지우고 새 키로 다시 추가해 주세요.")
        #expect(en.errAPIKeyRejected("DeepSeek")
                == "DeepSeek rejected the key (HTTP 401). Check that it has not expired or been deleted, then remove this card and add it again with a new key.")
        #expect(ko.errOpenRouterKeyRejected
                == "OpenRouter에서 키를 거부했습니다(HTTP 401). 키가 만료되거나 삭제되지 않았는지 확인한 뒤, 이 카드를 지우고 관리 키로 다시 추가해 주세요.")
        #expect(en.errOpenRouterKeyRejected
                == "OpenRouter rejected the key (HTTP 401). Check that it has not expired or been deleted, then remove this card and add it again with a management key.")
    }
}
