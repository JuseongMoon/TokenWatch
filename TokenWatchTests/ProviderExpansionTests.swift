//
//  ProviderExpansionTests.swift
//  TokenWatchTests
//
//  provider 확장(인증 추상화 + 잔액 표시 + 세션 캡처)의 순수 로직 검증.
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

    @Test func sessionCredentialCarriesAccountId() {
        let t = OAuthTokens.session("cookievalue", accountId: "user_42")
        #expect(t.accessToken == "cookievalue")
        #expect(t.accountId == "user_42")
        #expect(t.refreshToken == nil)
        #expect(t.isExpired == false)
    }

    // MARK: Cursor 세션 쿠키 파싱

    private func cookie(name: String, value: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name, .value: value, .domain: "cursor.com", .path: "/",
        ])!
    }

    @Test func cursorProbeExtractsUserIdFromPlainToken() {
        let cookies = [cookie(name: "WorkosCursorSessionToken", value: "user_abc::jwtpayload")]
        let t = CursorAuth.sessionProbe(cookies)
        #expect(t != nil)
        #expect(t?.accountId == "user_abc")
        #expect(t?.accessToken == "user_abc::jwtpayload")   // 쿠키 값 전체 보존
    }

    @Test func cursorProbeHandlesUrlEncodedSeparator() {
        let cookies = [cookie(name: "WorkosCursorSessionToken", value: "user_xyz%3A%3Ajwt")]
        let t = CursorAuth.sessionProbe(cookies)
        #expect(t?.accountId == "user_xyz")
    }

    @Test func cursorProbeRejectsPreAuthAndMissingCookies() {
        // "::" 없는 임시/불완전 쿠키는 세션으로 인정하지 않음.
        #expect(CursorAuth.sessionProbe([cookie(name: "WorkosCursorSessionToken", value: "pending")]) == nil)
        // 빈 값.
        #expect(CursorAuth.sessionProbe([cookie(name: "WorkosCursorSessionToken", value: "")]) == nil)
        // 다른 쿠키만 존재.
        #expect(CursorAuth.sessionProbe([cookie(name: "other", value: "user_a::jwt")]) == nil)
        // 쿠키 없음.
        #expect(CursorAuth.sessionProbe([]) == nil)
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

    @Test func oauthAndSessionProvidersHaveNoApiKeyURL() {
        for p in AgentProvider.allCases where p.authKind != .apiKey {
            #expect(p.apiKeyURL == nil, "\(p)는 apiKey 방식이 아닌데 apiKeyURL이 있음")
        }
    }

    @Test func providerCountMatchesExpectation() {
        // 확장 결과 스냅샷: 18개 provider가 등록돼 있어야 한다.
        #expect(AgentProvider.allCases.count == 18)
    }

    // MARK: protobuf 리더 (Grok gRPC-web 응답 파싱용)

    // 테스트용 최소 protobuf 인코더.
    private func varint(_ v: UInt64) -> [UInt8] {
        var v = v; var out: [UInt8] = []
        repeat {
            var b = UInt8(v & 0x7F); v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }
    private func tag(_ field: Int, _ wire: Int) -> [UInt8] { varint(UInt64(field << 3 | wire)) }
    private func fixed64LE(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * $0)) & 0xFF) } }

    /// field1=varint42, field2=double12.5, field3={ nested field1=varint 1_700_000_000 }
    private func sampleMessage() -> Data {
        var msg: [UInt8] = []
        msg += tag(1, 0) + varint(42)
        msg += tag(2, 1) + fixed64LE((12.5).bitPattern)
        let inner = tag(1, 0) + varint(1_700_000_000)
        msg += tag(3, 2) + varint(UInt64(inner.count)) + inner
        return Data(msg)
    }

    @Test func protobufParsesScalarAndNestedFields() {
        let fields = Protobuf.fields(sampleMessage())
        #expect(fields.count == 3)
        #expect(fields[0].varint == 42)
        #expect(fields[1].fixed64.map { Double(bitPattern: $0) } == 12.5)
        #expect(fields[2].bytes != nil)          // 중첩 메시지 바이트
    }

    @Test func protobufCollectNumbersRecurses() {
        let (doubles, varints) = Protobuf.collectNumbers(sampleMessage())
        #expect(doubles.contains(12.5))
        #expect(varints.contains(42))
        #expect(varints.contains(1_700_000_000))   // 중첩에서 회수
    }

    @Test func grpcWebFrameExtractsMessage() {
        let payload = sampleMessage()
        let len = payload.count
        var framed: [UInt8] = [0x00,                              // 압축 플래그(메시지)
                               UInt8((len >> 24) & 0xFF), UInt8((len >> 16) & 0xFF),
                               UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)]
        framed += [UInt8](payload)
        // trailer 프레임 하나 덧붙임(무시돼야 함).
        framed += [0x80, 0, 0, 0, 0]
        #expect(Protobuf.grpcWebMessage(Data(framed)) == payload)
    }

    // MARK: Grok 사용량 매핑(휴리스틱)

    @Test func grokMapPicksPercentAndReset() {
        let windows = GrokUsageClient.map(sampleMessage())
        #expect(windows.count == 1)
        #expect(windows.first?.usedPercent == 12.5)           // 0~100 double 우선
        #expect(windows.first?.style == .gauge)
        let reset = windows.first?.resetsAt?.timeIntervalSince1970
        #expect(reset == 1_700_000_000)                        // 타임스탬프 범위 varint
    }

    @Test func grokMapReturnsEmptyWhenNoSignal() {
        // 퍼센트로 볼 값이 없으면 빈 창(크래시 없음).
        #expect(GrokUsageClient.map(Data()).isEmpty)
    }

    // MARK: Grok 세션 쿠키 캡처

    private func grokCookie(_ name: String, _ value: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name, .value: value, .domain: ".grok.com", .path: "/",
        ])!
    }

    @Test func grokProbeIgnoresInfraCookies() {
        // 인프라 쿠키만 있으면 로그인 전으로 간주 → nil.
        let infra = [grokCookie("grok_device_id", "abc"), grokCookie("__cf_bm", "xyz")]
        #expect(GrokAuth.sessionProbe(infra) == nil)
    }

    @Test func grokProbeCapturesSessionCookies() {
        let cookies = [grokCookie("grok_device_id", "abc"), grokCookie("sso", "sessiontoken")]
        let t = GrokAuth.sessionProbe(cookies)
        #expect(t != nil)
        #expect(t?.accessToken.contains("sso=sessiontoken") == true)   // Cookie 헤더 직렬화
    }

    // MARK: Windsurf localStorage 캡처 + 사용량 매핑

    @Test func windsurfProbeNeedsAuthToken() {
        // 인증 토큰이 없으면 nil.
        #expect(WindsurfAuth.localStorageProbe(["theme": "dark"]) == nil)
    }

    @Test func windsurfProbePacksHeaders() {
        let store = [
            "x-auth-token": "AUTH", "x-devin-account-id": "acc1",
            "x-devin-primary-org-id": "org1", "unrelated": "x",
        ]
        let t = WindsurfAuth.localStorageProbe(store)
        #expect(t != nil)
        // accessToken엔 헤더 dict가 JSON으로 패킹된다.
        let headers = (try? JSONSerialization.jsonObject(with: Data((t?.accessToken ?? "").utf8)))
            as? [String: String]
        #expect(headers?["x-auth-token"] == "AUTH")
        #expect(headers?["x-devin-account-id"] == "acc1")
    }

    @Test func windsurfMapsDailyWeeklyQuota() {
        // remaining% → used% 변환(100 - remaining), 두 창.
        let json = #"{"dailyQuotaRemainingPercent": 70, "weeklyQuotaRemainingPercent": 40}"#
        let windows = WindsurfUsageClient.map(Data(json.utf8))
        #expect(windows.count == 2)
        #expect(windows.first(where: { $0.label == "Daily quota" })?.usedPercent == 30)
        #expect(windows.first(where: { $0.label == "Weekly quota" })?.usedPercent == 60)
    }

    @Test func windsurfMapAcceptsSnakeCase() {
        let json = #"{"daily_quota_remaining_percent": 90}"#
        let windows = WindsurfUsageClient.map(Data(json.utf8))
        #expect(windows.first?.usedPercent == 10)
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

    /// C 결정: stability(1개)는 곧바로 전체이상, deepseek·poe(2개)는 주의 없이 바로 이상.
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

    @Test func instatusComponentParsing() {
        // 대문자 상태값 + 그룹 부모("g1") 제외(자식 group.id로 참조됨). leaf c1(다운)+c2(정상)=이상.
        let json = #"{"components":[{"id":"g1","status":"OPERATIONAL","group":null},{"id":"c1","status":"MAJOROUTAGE","group":{"id":"g1"}},{"id":"c2","status":"OPERATIONAL","group":{"id":"g1"}}]}"#
        #expect(health(.instatus, json) == .major)
        #expect(health(.instatus, #"{"components":[{"id":"c","status":"UNDERMAINTENANCE"}]}"#) == .maintenance)
        #expect(health(.instatus, #"{"page":{}}"#) == nil)   // components 키 없음 → nil
    }

    @Test func betterStackComponentParsing() {
        // resource 2개(정상1+downtime1) → 이상. status_page_section은 집계에서 무시.
        let json = #"{"included":[{"type":"status_page_resource","attributes":{"status":"operational"}},{"type":"status_page_resource","attributes":{"status":"downtime"}},{"type":"status_page_section","attributes":{"name":"x"}}]}"#
        #expect(health(.betterstack, json) == .major)
        // maintenance 리소스 전부 → 전체점검
        #expect(health(.betterstack, #"{"included":[{"type":"status_page_resource","attributes":{"status":"maintenance"}}]}"#) == .maintenance)
        #expect(health(.betterstack, #"{"data":{"attributes":{}}}"#) == nil)   // included 없음 → nil
    }

    // MARK: 상태 페이지 메타데이터 불변식

    /// 머신리더블 엔드포인트가 없는(=메인 목록에 상태를 안 띄우는) provider 집합.
    private let noStatusSource: Set<AgentProvider> = [.openrouter, .grok, .leonardo]

    @Test func onlyProblematicProvidersLackStatusSource() {
        for p in AgentProvider.allCases {
            if noStatusSource.contains(p) {
                #expect(p.statusSource == nil, "\(p)는 상태 소스가 없어야 함")
            } else {
                #expect(p.statusSource != nil, "\(p)는 상태 소스가 있어야 함")
            }
        }
    }

    @Test func onlyLeonardoLacksStatusPage() {
        for p in AgentProvider.allCases {
            if p == .leonardo {
                #expect(p.statusPageURL == nil, "Leonardo는 상태 페이지가 없어야 함")
            } else {
                #expect(p.statusPageURL != nil, "\(p)는 상태 페이지 URL이 있어야 함")
            }
        }
    }

    @Test func statusSourceEndpointsAreComponentLists() {
        // 컴포넌트 개수 집계용: Atlassian은 /api/v2/components.json, Instatus는
        // /v2/components.json, Better Stack은 /index.json(included 리소스)으로 끝나야 한다.
        for p in AgentProvider.allCases {
            guard let source = p.statusSource else { continue }
            switch source.platform {
            case .atlassian:
                #expect(source.jsonURL.absoluteString.hasSuffix("/api/v2/components.json"), "\(p) atlassian 경로")
            case .instatus:
                #expect(source.jsonURL.absoluteString.hasSuffix("/v2/components.json"), "\(p) instatus 경로")
            case .betterstack:
                #expect(source.jsonURL.absoluteString.hasSuffix("/index.json"), "\(p) betterstack 경로")
            }
        }
    }
}
