//
//  FormURLEncoding.swift
//  TokenWatch
//
//  `application/x-www-form-urlencoded` 요청 본문 인코더(토큰 엔드포인트 공용).
//
//  `URLComponents.percentEncodedQuery`는 URL 쿼리 규칙이라 `+`를 그대로 둔다. 그런데 폼 디코더는
//  `+`를 공백으로 읽으므로, 값에 `+`가 섞이면 서버가 받는 값이 바뀐다. 그래서 RFC 3986 비예약 문자
//  (`A-Za-z0-9-._~`)만 남기고 나머지를 전부 퍼센트 인코딩한다.
//

import Foundation

nonisolated enum FormURLEncoding {
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    /// 순서를 보존하는 본문(테스트·서명 비교에 유리하다).
    static func body(_ params: [(String, String)]) -> Data {
        Data(params.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&").utf8)
    }

    /// 딕셔너리 입력 — 키 순서를 정렬해 본문을 결정적으로 만든다.
    static func body(_ params: [String: String]) -> Data {
        body(params.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
    }
}
