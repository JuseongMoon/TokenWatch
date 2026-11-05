//
//  LoopbackCallbackServer.swift
//  TokenWatch
//
//  OAuth 콜백을 받기 위한 1회용 루프백 HTTP 리스너.
//
//  왜 필요한가: claude.ai 인가 서버는 커스텀 스킴 redirect_uri를 거부한다(실기기 확인).
//  그래서 앱 안의 인증 시트(ASWebAuthenticationSession)에서 authorize를 열고, 인가 서버가
//  리다이렉트하는 `http://localhost:<포트>/callback`을 앱이 직접 받아 code를 얻는다.
//  (Claude Code CLI의 기본 로그인 흐름과 같은 구조다.) 흐름 전체는 `OAuthBrowserLoginCoordinator`가 맡는다.
//
//  응답은 `302 Found` → `tokenwatch://login-complete?code=…&state=…`이다. 인증 시트는 콜백
//  스킴으로 가는 리다이렉트를 보면 스스로 닫히므로, 이 응답이 브라우저에 닿아야 로그인 창이 닫힌다.
//  그래서 code는 응답 전송이 끝난 뒤에 넘긴다. 먼저 넘기면 받는 쪽이 곧바로 리스너를 정리하면서
//  이 연결까지 끊어 302가 도달하지 못한다(1.1.0 빌드 12의 결함).
//
//  보안: 127.0.0.1/::1 에만 바인딩해 LAN에 노출되지 않는다(루프백은 로컬 네트워크 권한 대상도
//  아니다). state가 일치하는 요청만 code를 넘기고 곧 닫는다. code는 PKCE verifier 없이는 토큰으로
//  바꿀 수 없다. 브라우저가 요청 없이 여는 예비 연결은 헤더가 오지 않아 그대로 버려진다.
//

import Foundation
import Network

/// 루프백 리스너 한 번의 종료 결과. 리스너당 정확히 한 번만 전달된다.
nonisolated enum LoopbackOutcome: Equatable, Sendable {
    /// 정상 콜백(code·state 검증 통과).
    case code(String, state: String)
    /// 콜백 경로·state가 맞는 OAuth 오류 리다이렉트(예: 사용자가 승인 거부 → `access_denied`).
    /// 값은 RFC 6749 `error` 코드뿐이다(`error_description` 원문은 싣지 않는다).
    case oauthError(String)
    /// 콜백 없이 리스너 수명이 끝났다.
    case timedOut
}

/// 콜백 요청 하나의 해석 결과(순수 함수 결과).
nonisolated enum LoopbackCallback: Equatable, Sendable {
    case code(String, state: String)
    case oauthError(String, state: String)
}

/// 루프백에 잠깐 떠서 OAuth 콜백 한 건만 받고 사라지는 최소 HTTP 서버.
@MainActor
final class LoopbackCallbackServer {
    /// 인증 시트를 닫는 콜백 주소(`tokenwatch://login-complete`). 시트의 callbackURLScheme과 같아야 한다.
    nonisolated static let sessionCallbackScheme = "tokenwatch"
    nonisolated static let sessionCallbackHost = "login-complete"

    /// 이 값과 일치하는 state를 가진 콜백만 받아들인다(CSRF 방어).
    private let expectedState: String
    /// 결과(code·OAuth 오류·시간 초과) 중 하나를 한 번만 받는다(응답 전송이 끝난 뒤).
    private let onOutcome: (LoopbackOutcome) -> Void
    /// 리스너 수명 — 지나면 닫고 `.timedOut`을 전달한다. 테스트는 짧게 준다.
    private let lifetime: Duration

    private var v4: NWListener?
    private var v6: NWListener?
    private var connections: [NWConnection] = []
    /// 결과 전달 여부 — 브라우저 재시도·시간 초과가 겹쳐도 한 번만 넘긴다.
    private var delivered = false
    private var timeoutTask: Task<Void, Never>?

    /// 리스너 수명 상한 기본값 — 이 시간이 지나면 스스로 닫고 시간 초과를 알린다.
    nonisolated static let defaultLifetime: Duration = .seconds(600)
    /// 요청 헤더 누적 상한. 콜백은 수백 바이트라 이보다 크면 우리 대상이 아니다.
    private static let maxRequestBytes = 16 * 1024

    init(expectedState: String, lifetime: Duration = LoopbackCallbackServer.defaultLifetime,
         onOutcome: @escaping (LoopbackOutcome) -> Void) {
        self.expectedState = expectedState
        self.lifetime = lifetime
        self.onOutcome = onOutcome
    }

    /// code만 받는 편의 생성자(오류·시간 초과는 무시한다).
    convenience init(expectedState: String, onCode: @escaping (String, String) -> Void) {
        self.init(expectedState: expectedState) { outcome in
            if case .code(let code, let state) = outcome { onCode(code, state) }
        }
    }

    // MARK: 시작 / 종료

    /// 임의 포트로 루프백 리스너를 띄우고 실제 포트를 돌려준다.
    func start() async throws -> UInt16 {
        let listener = try Self.makeListener(host: .ipv4(.loopback), port: .any)
        v4 = listener
        let port = try await Self.startAndWaitReady(listener) { [weak self] conn in
            self?.accept(conn)
        }

        // 브라우저가 `localhost`를 ::1로 먼저 시도할 수 있다. 같은 포트로 IPv6도 열어
        // 둔다(실패해도 IPv4로 폴백되므로 best-effort).
        if let v6Listener = try? Self.makeListener(host: .ipv6(.loopback),
                                                   port: NWEndpoint.Port(rawValue: port) ?? .any) {
            v6 = v6Listener
            _ = try? await Self.startAndWaitReady(v6Listener) { [weak self] conn in
                self?.accept(conn)
            }
        }

        timeoutTask = Task { [weak self, lifetime] in
            do { try await Task.sleep(for: lifetime) } catch { return }   // stop()으로 취소됨
            guard let self else { return }
            // 이미 결과를 넘겼으면(성공 직후 등) 시간 초과는 버린다 — 전달은 한 번뿐이다.
            self.deliver(.timedOut)
            self.stop()
        }
        return port
    }

    func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        v4?.cancel(); v4 = nil
        v6?.cancel(); v6 = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    private static func makeListener(host: NWEndpoint.Host, port: NWEndpoint.Port) throws -> NWListener {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 루프백에만 바인딩 — 같은 네트워크의 다른 기기에서는 접근할 수 없다.
        params.requiredLocalEndpoint = .hostPort(host: host, port: port)
        return try NWListener(using: params)
    }

    /// 리스너를 시작해 `.ready`까지 기다리고 바인딩된 포트를 돌려준다.
    private static func startAndWaitReady(_ listener: NWListener,
                                          onConnection: @escaping @MainActor (NWConnection) -> Void) async throws -> UInt16 {
        listener.newConnectionHandler = { conn in
            MainActor.assumeIsolated { onConnection(conn) }
        }
        return try await withCheckedThrowingContinuation { cont in
            let resumed = OneShot()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard resumed.claim() else { return }
                    cont.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error), .waiting(let error):
                    guard resumed.claim() else { return }
                    cont.resume(throwing: error)
                case .cancelled:
                    guard resumed.claim() else { return }
                    cont.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            // 콜백을 메인 큐로 받는다. 처리하는 요청이 한 건뿐이라 부하 문제가 없고,
            // MainActor 격리와 어긋나지 않는다.
            listener.start(queue: .main)
        }
    }

    /// continuation을 한 번만 resume하기 위한 래치(상태 콜백은 여러 번 올 수 있다).
    private final class OneShot: @unchecked Sendable {
        private nonisolated(unsafe) var done = false
        private let lock = NSLock()
        nonisolated func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    // MARK: 연결 처리

    private func accept(_ conn: NWConnection) {
        connections.append(conn)
        conn.start(queue: .main)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buf = buffer
                if let data { buf.append(data) }

                if error != nil {
                    conn.cancel()
                    return
                }
                // 헤더 끝(빈 줄)까지 받으면 요청 라인만 보면 된다(본문 없음).
                if let head = Self.requestLine(in: buf) {
                    self.handle(requestLine: head, on: conn)
                    return
                }
                if isComplete || buf.count >= Self.maxRequestBytes {
                    conn.cancel()
                    return
                }
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func handle(requestLine: String, on conn: NWConnection) {
        guard let target = Self.target(ofRequestLine: requestLine) else {
            respond(conn, status: "400 Bad Request", body: "bad request")
            return
        }
        // 경로·state가 맞지 않는 요청(다른 시도·외부 요청)은 404 — 현재 로그인을 끝내지 않는다.
        guard let parsed = Self.parseCallbackResult(target: target, expectedState: expectedState) else {
            respond(conn, status: "404 Not Found", body: "not found")
            return
        }

        let outcome: LoopbackOutcome
        let location: String
        switch parsed {
        case .code(let code, let state):
            outcome = .code(code, state: state)
            location = Self.redirectLocation(code: code, state: state)
        case .oauthError(let error, let state):
            outcome = .oauthError(error)
            location = Self.redirectLocation(error: error, state: state)
        }

        // 302를 먼저 보내고 전송이 끝난 뒤 결과를 넘긴다(파일 머리말 참고). 전송이 실패해도
        // (브라우저가 이미 연결을 닫음 등) 결과는 넘긴다 — 교환에는 code만 있으면 된다.
        respond(conn, status: "302 Found", extraHeaders: ["Location: \(location)"], body: "") {
            self.deliver(outcome)
        }
        // 응답이 나갈 시간을 준 뒤 리스너를 접는다. 소유자가 참조를 놓아도 실행되도록 강하게 붙잡는다.
        // 전송 완료 콜백이 끝내 오지 않는 경우에도 여기서 결과를 넘긴다(전달은 한 번뿐이다).
        Task {
            try? await Task.sleep(for: .seconds(1))
            self.deliver(outcome)
            self.stop()
        }
    }

    private func deliver(_ outcome: LoopbackOutcome) {
        guard !delivered else { return }
        delivered = true
        onOutcome(outcome)
    }

    private func respond(_ conn: NWConnection, status: String, extraHeaders: [String] = [],
                         body: String, contentType: String = "text/plain; charset=utf-8",
                         onSent: (@MainActor () -> Void)? = nil) {
        let bodyData = Data(body.utf8)
        let lines = ["HTTP/1.1 \(status)"] + extraHeaders + [
            "Content-Type: \(contentType)",
            "Content-Length: \(bodyData.count)",
            "Cache-Control: no-store",
            "Connection: close",
        ]
        var out = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        out.append(bodyData)
        conn.send(content: out, completion: .contentProcessed { _ in
            // 연결을 메인 큐에서 시작했으므로 완료 콜백도 메인 큐에서 온다.
            MainActor.assumeIsolated { onSent?() }
            conn.cancel()
        })
    }

    // MARK: 파싱 (순수 함수 — 테스트 대상)

    /// 헤더 끝(\r\n\r\n 또는 \n\n)까지 도착했으면 첫 줄(요청 라인)을 돌려준다.
    nonisolated static func requestLine(in buffer: Data) -> String? {
        guard let text = String(data: buffer, encoding: .utf8) ?? String(data: buffer, encoding: .isoLatin1)
        else { return nil }
        guard text.contains("\r\n\r\n") || text.contains("\n\n") else { return nil }
        return text.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    /// `GET /callback?code=… HTTP/1.1` → `/callback?code=…`
    nonisolated static func target(ofRequestLine line: String) -> String? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    /// 콜백 경로이고 state가 기대값과 같을 때만 (code, state)를 돌려준다.
    nonisolated static func parseCallback(target: String, expectedState: String) -> (code: String, state: String)? {
        guard case .code(let code, let state)? = parseCallbackResult(target: target, expectedState: expectedState)
        else { return nil }
        return (code, state)
    }

    /// 콜백 경로의 요청을 해석한다.
    /// - code 콜백: state가 기대값과 같아야만 받는다(CSRF 방어 — 기존과 같다).
    /// - 오류 콜백(code 없이 `error`): state가 아예 없으면 받아들이고(인가 서버가 오류 리다이렉트에
    ///   state를 싣지 않는 경우 — xAI 공식 CLI도 오류 콜백의 state를 검증하지 않는다), state가 있는데
    ///   기대값과 다르면 다른 시도의 응답으로 보고 무시한다.
    /// 경로가 다르거나 둘 다 해당하지 않으면 nil.
    nonisolated static func parseCallbackResult(target: String, expectedState: String) -> LoopbackCallback? {
        guard let comp = URLComponents(string: "http://localhost\(target)"),
              comp.path == "/callback"
        else { return nil }
        let items = comp.queryItems ?? []
        let state = items.first(where: { $0.name == "state" })?.value
        if let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty {
            guard state == expectedState else { return nil }
            return .code(code, state: expectedState)
        }
        guard let error = sanitizedOAuthError(items.first(where: { $0.name == "error" })?.value) else {
            return nil
        }
        guard state == nil || state == expectedState else { return nil }
        // 시트로 돌려보내는 리다이렉트에는 우리 state를 실어, 시트 쪽 검증(parseSessionError)과 맞춘다.
        return .oauthError(error, state: expectedState)
    }

    /// OAuth `error` 값은 RFC 6749상 출력 가능한 ASCII 토큰이다. 그 형태(`[A-Za-z0-9_.-]`, 64자 이내)만 받는다.
    nonisolated static func sanitizedOAuthError(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 64,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) })
        else { return nil }
        return value
    }

    /// 인증 시트를 닫는 리다이렉트 주소. code/state는 퍼센트 인코딩된다.
    nonisolated static func redirectLocation(code: String, state: String) -> String {
        var comp = URLComponents()
        comp.scheme = sessionCallbackScheme
        comp.host = sessionCallbackHost
        comp.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "state", value: state),
        ]
        return comp.string ?? "\(sessionCallbackScheme)://\(sessionCallbackHost)"
    }

    /// 오류 콜백을 인증 시트에 돌려보내는 주소 — 시트가 스스로 닫히게 한다.
    nonisolated static func redirectLocation(error: String, state: String) -> String {
        var comp = URLComponents()
        comp.scheme = sessionCallbackScheme
        comp.host = sessionCallbackHost
        comp.queryItems = [
            URLQueryItem(name: "error", value: error),
            URLQueryItem(name: "state", value: state),
        ]
        return comp.string ?? "\(sessionCallbackScheme)://\(sessionCallbackHost)"
    }

    /// 인증 시트가 돌려준 콜백 URL의 OAuth 오류. `expectedState`와 같을 때만 돌려준다.
    nonisolated static func parseSessionError(_ url: URL, expectedState: String) -> String? {
        guard url.scheme == sessionCallbackScheme, url.host == sessionCallbackHost,
              let comp = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let items = comp.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == expectedState else { return nil }
        return sanitizedOAuthError(items.first(where: { $0.name == "error" })?.value)
    }

    /// 인증 시트가 돌려준 콜백 URL에서 code/state를 뽑는다. 우리 콜백 주소가 아니면 nil.
    nonisolated static func parseSessionCallback(_ url: URL) -> (code: String, state: String)? {
        guard url.scheme == sessionCallbackScheme, url.host == sessionCallbackHost,
              let comp = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let items = comp.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty,
              let state = items.first(where: { $0.name == "state" })?.value
        else { return nil }
        return (code, state)
    }
}
