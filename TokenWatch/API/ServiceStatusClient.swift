//
//  ServiceStatusClient.swift
//  TokenWatch
//
//  각 provider의 "서비스 운영 상태"를 공식 상태 페이지의 공개 JSON에서 읽어온다.
//  사용량(usage)과는 별개의 축이라 인증이 필요 없고, provider 계정 없이도 조회된다.
//
//  ── 종합 지표가 아니라 "컴포넌트 개수"로 판정한다 ──
//  예전에는 상태 페이지의 최상위 종합 지표 하나만 읽었는데, 그러면 코딩과 무관한
//  컴포넌트(예: OpenAI "Image Generation") 하나만 장애나도 신호등 전체가 물들었다.
//  이제는 개별 컴포넌트 상태를 모두 세서 "다운 비율"로 4단계를 매긴다:
//    정상    : 전 컴포넌트 정상
//    주의    : 하나라도 비정상(단, 절반 미만)
//    이상    : 절반 이상 다운               (UI: 빨강 점멸)
//    전체이상 : 전부 다운                    (UI: 검정에 가까운 회색 점멸)
//    전체점검 : 전 컴포넌트가 점검중          (UI: 신호등 대신 "공사중" 픽셀아트)
//  점검(maintenance)도 "다운"으로 카운트하되, 전부 점검일 때만 별도 상태로 뺀다.
//
//  세 가지 상태 페이지 플랫폼을 지원한다(컴포넌트 목록 엔드포인트가 각각 다르다):
//   - Atlassian Statuspage: GET /api/v2/components.json → components[].status (소문자_언더스코어)
//   - Instatus:            GET /v2/components.json      → components[].status (대문자)
//   - Better Stack:        GET /index.json              → included[type=status_page_resource].attributes.status
//
//  머신리더블 엔드포인트가 없는 provider(OpenRouter·Grok·Leonardo)는 statusSource가
//  nil이라 이 클라이언트를 타지 않고, 메인 목록에 상태 점을 아예 그리지 않는다.
//

import Foundation

/// 서비스 운영 상태 — 개별 컴포넌트를 집계한 앱 공통 단계값.
enum ServiceHealth: String, Sendable, Equatable {
    case operational   // 정상    — 전 컴포넌트 정상
    case caution       // 주의    — 1개 이상 비정상(절반 미만)
    case major         // 이상    — 절반 이상 다운
    case totalOutage   // 전체이상 — 전부 다운
    case maintenance   // 전체점검 — 전 컴포넌트 점검중("공사중")
    case unknown       // 판정 불가 — 상세 화면에서만 노출(방어적)
}

/// 개별 컴포넌트를 앱 공통 3분류로 정규화한 것. 판정 로직은 이 배열만 보고 계산한다.
enum ComponentStatus: Sendable, Equatable {
    case operational   // 정상
    case maintenance   // 점검 중
    case down          // 그 외 전부(성능저하/부분장애/전체장애/미상) — 해석②: operational이 아니면 다운
}

/// provider의 상태 페이지가 쓰는 플랫폼. 컴포넌트 목록 파싱 방식을 결정한다.
enum StatusPlatform: Sendable, Equatable {
    case atlassian     // components[].status: operational/degraded_performance/partial_outage/major_outage/under_maintenance
    case instatus      // components[].status: OPERATIONAL/DEGRADEDPERFORMANCE/PARTIALOUTAGE/MAJOROUTAGE/UNDERMAINTENANCE
    case betterstack   // included[status_page_resource].attributes.status: operational/degraded/downtime/maintenance
}

/// provider의 컴포넌트 목록을 조회할 공개 JSON 엔드포인트 + 그 파싱 플랫폼.
struct ServiceStatusSource: Sendable, Equatable {
    let platform: StatusPlatform
    let jsonURL: URL
}

enum ServiceStatusClient {
    /// 상태 페이지 컴포넌트 JSON을 조회해 정규화된 ServiceHealth로 돌려준다. 예외는 던지지
    /// 않고 반환값으로 실패 양상을 구분한다:
    ///  - `nil` : 조회·파싱 실패(네트워크/타임아웃, 비2xx, 형식 불일치, 컴포넌트 0개 등).
    ///            "일시적으로 못 봤다"는 뜻이라, 호출측은 직전 상태(last-good)를 유지하고
    ///            곧바로 재시도할 수 있게 해야 한다.
    /// 한 번의 일시적 실패가 정상 배지를 덮어쓰거나 스로틀에 고착되지 않게 하기 위함이다.
    static func fetch(_ source: ServiceStatusSource) async -> ServiceHealth? {
        var req = URLRequest(url: source.jsonURL)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("TokenWatch/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        req.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }
        return parse(source.platform, data: data)
    }

    /// 플랫폼별 JSON → 컴포넌트 배열 → ServiceHealth(순수 함수, 단위 테스트 대상).
    /// `nil` = 파싱 실패(형식 불일치·필드 없음) 또는 컴포넌트 0개.
    static func parse(_ platform: StatusPlatform, data: Data) -> ServiceHealth? {
        let statuses: [ComponentStatus]?
        switch platform {
        case .atlassian:   statuses = atlassianComponents(data)
        case .instatus:    statuses = instatusComponents(data)
        case .betterstack: statuses = betterstackComponents(data)
        }
        guard let statuses else { return nil }
        return classify(statuses)
    }

    // MARK: - 판정 로직 (해석②: operational이 아니면 전부 "다운", 점검도 다운으로 카운트)

    /// leaf 컴포넌트 상태 배열을 4단계(+전체점검)로 집계한다.
    /// 순서(가장 심한 것부터): 전체점검 → 정상 → 전체이상 → 이상 → 주의.
    static func classify(_ statuses: [ComponentStatus]) -> ServiceHealth? {
        let n = statuses.count
        guard n > 0 else { return nil }   // 컴포넌트 0개 = 판정 불가 → 일시적 실패로 취급
        let maintenance = statuses.lazy.filter { $0 == .maintenance }.count
        let down = statuses.lazy.filter { $0 != .operational }.count   // 점검 포함(B)
        if maintenance == n { return .maintenance }   // 전부 점검중 → "공사중"
        if down == 0        { return .operational }   // 전부 정상
        if down == n        { return .totalOutage }   // 전부 다운
        if down * 2 >= n    { return .major }         // 절반 이상 다운 (⌈n/2⌉)
        return .caution                               // 하나라도 비정상(절반 미만)
    }

    // MARK: - 플랫폼별 컴포넌트 파서

    // Atlassian: components.json. group==true 인 항목은 그룹 헤더라 leaf 집계에서 제외한다.
    private struct AtlassianComponents: Decodable {
        struct Component: Decodable {
            let status: String?
            let group: Bool?
        }
        let components: [Component]?
    }

    static func atlassianComponents(_ data: Data) -> [ComponentStatus]? {
        guard let decoded = try? JSONDecoder().decode(AtlassianComponents.self, from: data),
              let components = decoded.components else { return nil }
        return components
            .filter { $0.group != true }
            .map { atlassianStatus($0.status) }
    }

    private static func atlassianStatus(_ s: String?) -> ComponentStatus {
        switch s?.lowercased() {
        case "operational":       return .operational
        case "under_maintenance": return .maintenance
        default:                  return .down   // degraded_performance/partial_outage/major_outage/미상
        }
    }

    // Instatus: /v2/components.json. 그룹 "부모"(다른 컴포넌트의 group.id로 참조되는 항목)는
    // 롤업 카테고리라 leaf 집계에서 제외한다.
    private struct InstatusComponents: Decodable {
        struct Component: Decodable {
            struct Group: Decodable { let id: String? }
            let id: String?
            let status: String?
            let group: Group?
        }
        let components: [Component]?
    }

    static func instatusComponents(_ data: Data) -> [ComponentStatus]? {
        guard let decoded = try? JSONDecoder().decode(InstatusComponents.self, from: data),
              let components = decoded.components else { return nil }
        let parentIDs = Set(components.compactMap { $0.group?.id })
        return components
            .filter { comp in comp.id.map { !parentIDs.contains($0) } ?? true }
            .map { instatusStatus($0.status) }
    }

    private static func instatusStatus(_ s: String?) -> ComponentStatus {
        switch s?.uppercased() {
        case "OPERATIONAL":      return .operational
        case "UNDERMAINTENANCE": return .maintenance
        default:                 return .down   // DEGRADEDPERFORMANCE/PARTIALOUTAGE/MAJOROUTAGE/미상
        }
    }

    // Better Stack: /index.json. 실제 리소스는 included[] 안의 type=status_page_resource.
    private struct BetterStackPage: Decodable {
        struct Included: Decodable {
            struct Attributes: Decodable { let status: String? }
            let type: String?
            let attributes: Attributes?
        }
        let included: [Included]?
    }

    static func betterstackComponents(_ data: Data) -> [ComponentStatus]? {
        guard let decoded = try? JSONDecoder().decode(BetterStackPage.self, from: data),
              let included = decoded.included else { return nil }
        let resources = included.filter { $0.type == "status_page_resource" }
        guard !resources.isEmpty else { return [] }   // 리소스 0개 → classify가 nil(일시적 실패)로
        return resources.map { betterstackStatus($0.attributes?.status) }
    }

    private static func betterstackStatus(_ s: String?) -> ComponentStatus {
        switch s?.lowercased() {
        case "operational":                      return .operational
        case "maintenance", "under_maintenance": return .maintenance
        default:                                 return .down   // degraded/downtime/미상
        }
    }
}
