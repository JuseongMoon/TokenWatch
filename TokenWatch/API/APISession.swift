//
//  APISession.swift
//  TokenWatch
//
//  자격증명(토큰·API 키)이 실리는 요청 전용 URLSession.
//  ephemeral 구성이라 응답 캐시·쿠키·자격증명이 디스크에 남지 않는다(전부 메모리).
//  공개 상태 페이지 조회(ServiceStatusClient)는 민감하지 않아 공유 세션을 그대로 쓴다.
//

import Foundation

enum APISession {
    nonisolated static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        return URLSession(configuration: config)
    }()
}
