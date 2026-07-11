//
//  ServiceStatusClient.swift
//  TokenWatch
//
//  각 provider의 "서비스 운영 상태"(정상/장애/점검)를 공식 상태 페이지의
//  공개 JSON 엔드포인트에서 읽어온다. 사용량(usage)과는 별개의 축이라 인증이
//  필요 없고, provider 계정 없이도 조회된다.
//
//  세 가지 상태 페이지 플랫폼을 지원한다(대부분 이 셋 중 하나를 쓴다):
//   - Atlassian Statuspage: GET /api/v2/status.json → status.indicator
//   - Instatus:            GET /summary.json        → page.status
//   - Better Stack:        GET /index.json          → data.attributes.aggregate_state
//
//  머신리더블 엔드포인트가 없는 provider(OpenRouter·Grok·Leonardo)는 statusSource가
//  nil이라 이 클라이언트를 타지 않고, UI에서 "알 수 없음"으로 표시된다.
//

import Foundation

/// 서비스 운영 상태 — 상태 페이지 표준값들을 앱 공통 5단계로 정규화한 것.
enum ServiceHealth: String, Sendable, Equatable {
    case operational   // 정상
    case degraded      // 일부 저하(부분 장애/성능 저하)
    case major         // 주요 장애/다운
    case maintenance   // 점검 중
    case unknown       // 알 수 없음(미지원 엔드포인트 또는 조회 실패)
}

/// provider의 상태 페이지가 쓰는 플랫폼. 파싱 방식을 결정한다.
enum StatusPlatform: Sendable, Equatable {
    case atlassian     // status.indicator: none/minor/major/critical
    case instatus      // page.status: UP/HASISSUES/UNDERMAINTENANCE
    case betterstack   // data.attributes.aggregate_state: operational/degraded/downtime/maintenance
}

/// provider의 상태를 조회할 공개 JSON 엔드포인트 + 그 파싱 플랫폼.
struct ServiceStatusSource: Sendable, Equatable {
    let platform: StatusPlatform
    let jsonURL: URL
}

enum ServiceStatusClient {
    /// 상태 페이지 JSON을 조회해 정규화된 ServiceHealth로 돌려준다.
    /// 네트워크/디코딩 실패는 예외를 던지지 않고 `.unknown`으로 흡수한다
    /// (상태 배지는 부가 정보라 실패해도 사용량 화면을 방해하지 않아야 한다).
    static func fetch(_ source: ServiceStatusSource) async -> ServiceHealth {
        var req = URLRequest(url: source.jsonURL)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("TokenWatch/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        req.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return .unknown
        }
        return parse(source.platform, data: data)
    }

    /// 플랫폼별 JSON → ServiceHealth 매핑(순수 함수, 단위 테스트 대상).
    static func parse(_ platform: StatusPlatform, data: Data) -> ServiceHealth {
        switch platform {
        case .atlassian:   return parseAtlassian(data)
        case .instatus:    return parseInstatus(data)
        case .betterstack: return parseBetterStack(data)
        }
    }

    // MARK: - 플랫폼별 파서

    private struct AtlassianStatus: Decodable {
        struct Status: Decodable { let indicator: String? }
        let status: Status?
    }

    static func parseAtlassian(_ data: Data) -> ServiceHealth {
        guard let decoded = try? JSONDecoder().decode(AtlassianStatus.self, from: data),
              let indicator = decoded.status?.indicator?.lowercased() else { return .unknown }
        switch indicator {
        case "none":                 return .operational
        case "minor":                return .degraded
        case "major", "critical":    return .major
        case "maintenance":          return .maintenance
        default:                     return .unknown
        }
    }

    private struct InstatusSummary: Decodable {
        struct Page: Decodable { let status: String? }
        let page: Page?
    }

    static func parseInstatus(_ data: Data) -> ServiceHealth {
        guard let decoded = try? JSONDecoder().decode(InstatusSummary.self, from: data),
              let status = decoded.page?.status?.uppercased() else { return .unknown }
        switch status {
        case "UP":              return .operational
        case "HASISSUES":       return .degraded
        case "DOWN":            return .major
        case "UNDERMAINTENANCE": return .maintenance
        default:                return .unknown
        }
    }

    private struct BetterStackStatus: Decodable {
        struct Data: Decodable {
            struct Attributes: Decodable { let aggregate_state: String? }
            let attributes: Attributes?
        }
        let data: Data?
    }

    static func parseBetterStack(_ data: Data) -> ServiceHealth {
        guard let decoded = try? JSONDecoder().decode(BetterStackStatus.self, from: data),
              let state = decoded.data?.attributes?.aggregate_state?.lowercased() else { return .unknown }
        switch state {
        case "operational":                  return .operational
        case "degraded":                     return .degraded
        case "downtime":                     return .major
        case "maintenance", "under_maintenance": return .maintenance
        default:                             return .unknown
        }
    }
}
