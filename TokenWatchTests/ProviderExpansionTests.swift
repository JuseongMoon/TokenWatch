//
//  ProviderExpansionTests.swift
//  TokenWatchTests
//
//  provider 메타데이터·인증 추상화·잔액 표시·서비스 상태 판정의 순수 로직 검증.
//  네트워크 없이 결정적으로 돌아가는 부분만 테스트한다.
//

import Testing
import Foundation
@testable import TokenWatch

struct ProviderExpansionTests {

    // MARK: 자격증명 팩토리

    @Test func apiKeyCredentialHasNoRefreshOrExpiry() {
        let t = OAuthTokens.apiKey("  sk-abc123  ")
        #expect(t.accessToken == "sk-abc123")      // 앞뒤 공백 트리밍
        #expect(t.refreshToken == nil)
        #expect(t.expiresAt == nil)
        #expect(t.isExpired == false)               // 만료 없음 → 항상 유효
        #expect(t.scopes.isEmpty)
    }

    // MARK: Retry-After 파싱

    @Test func retryAfterParsesSecondsAndDates() {
        let secs = parseRetryAfter("120")
        #expect(secs != nil)
        #expect(abs((secs?.timeIntervalSinceNow ?? 0) - 120) < 5)

        #expect(parseRetryAfter(nil) == nil)
        #expect(parseRetryAfter("") == nil)

        let httpDate = parseRetryAfter("Wed, 21 Oct 2099 07:28:00 GMT")
        #expect(httpDate != nil)
    }

    // MARK: 잔액(balance) 표시 창

    @Test func balanceWindowKeepsValueText() {
        let w = UsageWindow(label: "Credits", usedPercent: 0, resetsAt: nil,
                            kind: .weekly, style: .balance, valueText: "6.50 USD")
        #expect(w.style == .balance)
        #expect(w.valueText == "6.50 USD")
    }

    @Test func defaultWindowStyleIsGauge() {
        let w = UsageWindow(label: "Session", usedPercent: 40, resetsAt: nil, kind: .session)
        #expect(w.style == .gauge)
        #expect(w.valueText == nil)
        #expect(w.remainingPercent == 60)
    }

    // MARK: provider 메타데이터 불변식 (switch 실수/누락 방지)

    @Test func everyProviderHasDisplayMetadata() {
        for p in AgentProvider.allCases {
            #expect(!p.displayName.isEmpty, "\(p) displayName 누락")
            #expect(!p.terminalTag.isEmpty, "\(p) terminalTag 누락")
            #expect(!p.symbolName.isEmpty, "\(p) symbolName 누락")
            #expect(p.id == p.rawValue)
        }
    }

    @Test func apiKeyProvidersExposeKeyIssuanceURL() {
        for p in AgentProvider.allCases where p.authKind == .apiKey {
            #expect(p.apiKeyURL != nil, "\(p)는 apiKey 방식인데 apiKeyURL이 없음")
        }
    }

    @Test func nonAPIKeyProvidersHaveNoApiKeyURL() {
        for p in AgentProvider.allCases where p.authKind != .apiKey {
            #expect(p.apiKeyURL == nil, "\(p)는 apiKey 방식이 아닌데 apiKeyURL이 있음")
        }
    }

    @Test func providerCountMatchesExpectation() {
        // 2026-08 정리 결과 스냅샷: 공식 API 기반 7개만 남긴다.
        // (Claude·Codex=OAuth, Copilot=device flow, OpenRouter·DeepSeek·Poe·ElevenLabs=API키)
        #expect(AgentProvider.allCases.count == 7)
    }

    // MARK: 저장 데이터 마이그레이션 (지원 종료 provider 걸러내기)

    @Test func decodeAgentsDropsUnsupportedProviders() {
        // 구버전 저장 데이터에 지원 종료된 provider(cursor)가 섞여 있어도
        // 나머지 에이전트는 살아남고, 걸러진 ID는 고아 정리 대상으로 반환돼야 한다.
        let json = #"""
        [{"id":"11111111-1111-1111-1111-111111111111","provider":"claude","accountLabel":"pro"},
         {"id":"22222222-2222-2222-2222-222222222222","provider":"cursor"},
         {"id":"33333333-3333-3333-3333-333333333333","provider":"codex","accountLabel":"dev@x.io"}]
        """#
        let (kept, dropped) = AgentStore.decodeAgents(from: Data(json.utf8))
        #expect(kept.map(\.provider) == [.claude, .codex])
        #expect(kept.first?.accountLabel == "pro")
        #expect(dropped == [UUID(uuidString: "22222222-2222-2222-2222-222222222222")!])
    }

    @Test func decodeAgentsKeepsAllSupportedProviders() {
        // 지원 provider만 있으면 그대로 전부 유지.
        let json = #"[{"id":"44444444-4444-4444-4444-444444444444","provider":"poe"}]"#
        let (kept, dropped) = AgentStore.decodeAgents(from: Data(json.utf8))
        #expect(kept.count == 1)
        #expect(dropped.isEmpty)
    }

    @Test func decodeAgentsToleratesGarbage() {
        let (kept, dropped) = AgentStore.decodeAgents(from: Data("not json".utf8))
        #expect(kept.isEmpty)
        #expect(dropped.isEmpty)
    }

    // MARK: 서비스 운영 상태 — 컴포넌트 개수 집계 판정

    private func health(_ platform: StatusPlatform, _ json: String) -> ServiceHealth? {
        ServiceStatusClient.parse(platform, data: Data(json.utf8))
    }

    /// 해석②(operational이 아니면 전부 "다운") + 점검도 다운 카운트, 전부 점검만 별도.
    @Test func classifyThresholds() {
        #expect(ServiceStatusClient.classify([.operational, .operational, .operational]) == .operational)
        // 3개 중 1다운(절반 미만) → 주의
        #expect(ServiceStatusClient.classify([.down, .operational, .operational]) == .caution)
        // 절반 이상 다운 → 이상 (3개 중 2, 4개 중 2)
        #expect(ServiceStatusClient.classify([.down, .down, .operational]) == .major)
        #expect(ServiceStatusClient.classify([.down, .down, .operational, .operational]) == .major)
        // 전부 다운 → 전체이상
        #expect(ServiceStatusClient.classify([.down, .down]) == .totalOutage)
        // 전부 점검중 → 전체점검(공사중)
        #expect(ServiceStatusClient.classify([.maintenance, .maintenance]) == .maintenance)
        // 점검도 다운으로 카운트(B): 점검2+정상1(3개) → 절반 이상 → 이상
        #expect(ServiceStatusClient.classify([.maintenance, .maintenance, .operational]) == .major)
        // 점검1+정상2 → 주의(절반 미만)
        #expect(ServiceStatusClient.classify([.maintenance, .operational, .operational]) == .caution)
        // 컴포넌트 0개 → nil(판정 불가 → last-good 유지)
        #expect(ServiceStatusClient.classify([]) == nil)
    }

    /// C 결정: 컴포넌트가 1~2개뿐인 페이지(deepseek·poe=2개)는 주의 단계 없이 바로 이상/전체이상.
    @Test func edgeCaseSmallComponentCounts() {
        #expect(ServiceStatusClient.classify([.operational]) == .operational)
        #expect(ServiceStatusClient.classify([.down]) == .totalOutage)          // 1개 다운 = 전체이상
        #expect(ServiceStatusClient.classify([.maintenance]) == .maintenance)   // 1개 점검 = 전체점검
        #expect(ServiceStatusClient.classify([.down, .operational]) == .major)  // 2개 1다운 = 이상(주의 없음)
    }

    @Test func atlassianComponentParsing() {
        // 정상2 + partial1(3개 중 1다운) → 주의
        #expect(health(.atlassian, #"{"components":[{"status":"operational","group":false},{"status":"operational","group":false},{"status":"partial_outage","group":false}]}"#) == .caution)
        // 그룹 헤더(group=true)는 leaf 집계에서 제외 → 정상 leaf 1개만 → 정상
        #expect(health(.atlassian, #"{"components":[{"status":"major_outage","group":true},{"status":"operational","group":false}]}"#) == .operational)
        // under_maintenance = 점검, 전부 점검 → 전체점검
        #expect(health(.atlassian, #"{"components":[{"status":"under_maintenance"}]}"#) == .maintenance)
        // 형식 오류·필드 없음 → nil
        #expect(health(.atlassian, #"{}"#) == nil)
        #expect(health(.atlassian, "not json") == nil)
    }

    // MARK: 상태 페이지 메타데이터 불변식

    /// 머신리더블 엔드포인트가 없는(=메인 목록에 상태를 안 띄우는) provider 집합.
    private let noStatusSource: Set<AgentProvider> = [.openrouter]

    @Test func onlyOpenRouterLacksStatusSource() {
        for p in AgentProvider.allCases {
            if noStatusSource.contains(p) {
                #expect(p.statusSource == nil, "\(p)는 상태 소스가 없어야 함")
            } else {
                #expect(p.statusSource != nil, "\(p)는 상태 소스가 있어야 함")
            }
        }
    }

    @Test func everyProviderHasStatusPage() {
        for p in AgentProvider.allCases {
            #expect(p.statusPageURL != nil, "\(p)는 상태 페이지 URL이 있어야 함")
        }
    }

    @Test func statusSourceEndpointsAreComponentLists() {
        // 컴포넌트 개수 집계용: Atlassian은 /api/v2/components.json으로 끝나야 한다.
        for p in AgentProvider.allCases {
            guard let source = p.statusSource else { continue }
            switch source.platform {
            case .atlassian:
                #expect(source.jsonURL.absoluteString.hasSuffix("/api/v2/components.json"), "\(p) atlassian 경로")
            }
        }
    }
}
