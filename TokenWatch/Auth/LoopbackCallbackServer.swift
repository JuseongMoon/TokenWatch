//
//  LoopbackCallbackServer.swift
//  TokenWatch
//
//  OAuth 콜백을 받기 위한 1회용 루프백 HTTP 리스너.
//
//  왜 필요한가: claude.ai 로그인 페이지의 구글/애플 버튼은 `window.open` 팝업으로
//  동작한다. WKWebView(팝업 미지원)는 물론 ASWebAuthenticationSession/
//  SFSafariViewController도 진짜 팝업 창을 만들지 못해 소셜 로그인이 실패한다.
//  그래서 로그인은 외부 브라우저(Safari)에서 진행하고, 인가 서버가 리다이렉트하는
//  `http://localhost:<포트>/callback`을 앱이 직접 받아 code를 얻는다.
//  (Claude Code CLI의 기본 로그인 흐름과 같은 구조다.)
//
//  실기기 확인(2026-09-12): 앱이 백그라운드에서 정지된 동안 도착한 요청은 커널이 큐잉했다가
//  복귀 시 읽힌다(로그인은 성공). 그동안 Safari는 타임아웃 페이지를 보여주므로, 승인 단계는
//  앱 실행 유예(약 30초) 안에 끝나야 완료 페이지가 뜬다 → BrowserLoginView가 로그인과 승인을
//  두 단계로 분리하는 이유.
//
//  보안: 127.0.0.1/::1 에만 바인딩해 LAN에 노출되지 않는다. state가 일치하는 요청
//  하나만 처리하고 즉시 닫는다. code는 PKCE verifier 없이는 토큰으로 바꿀 수 없다.
//

import Foundation
import Network

/// 루프백에 잠깐 떠서 OAuth 콜백 한 건만 받고 사라지는 최소 HTTP 서버.
@MainActor
final class LoopbackCallbackServer {
    /// 이 값과 일치하는 state를 가진 콜백만 받아들인다(CSRF 방어).
    private let expectedState: String
    /// code/state를 받으면 한 번만 호출된다.
    private let onCode: (String, String) -> Void

    private var v4: NWListener?
    private var v6: NWListener?
    private var connections: [NWConnection] = []
    private var finished = false
    private var timeoutTask: Task<Void, Never>?

    /// 리스너 수명 상한 — 이 시간이 지나면 스스로 닫는다(리소스 누수 방지).
    private static let lifetime: Duration = .seconds(600)
    /// 요청 헤더 누적 상한. 콜백은 수백 바이트라 이보다 크면 우리 대상이 아니다.
    private static let maxRequestBytes = 16 * 1024

    init(expectedState: String, onCode: @escaping (String, String) -> Void) {
        self.expectedState = expectedState
        self.onCode = onCode
    }

    // MARK: 시작 / 종료

    /// 임의 포트로 루프백 리스너를 띄우고 실제 포트를 돌려준다.
    func start() async throws -> UInt16 {
        let listener = try Self.makeListener(host: .ipv4(.loopback), port: .any)
        v4 = listener
        let port = try await Self.startAndWaitReady(listener) { [weak self] conn in
            self?.accept(conn)
        }

        // Safari가 `localhost`를 ::1로 먼저 시도할 수 있다. 같은 포트로 IPv6도 열어
        // 둔다(실패해도 IPv4로 폴백되므로 best-effort).
        if let v6Listener = try? Self.makeListener(host: .ipv6(.loopback),
                                                   port: NWEndpoint.Port(rawValue: port) ?? .any) {
            v6 = v6Listener
            _ = try? await Self.startAndWaitReady(v6Listener) { [weak self] conn in
                self?.accept(conn)
            }
        }

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.lifetime)
            self?.stop()
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
        guard let parsed = Self.parseCallback(target: target, expectedState: expectedState) else {
            respond(conn, status: "404 Not Found", body: "not found")
            return
        }

        // code를 먼저 넘긴다. 앱이 백그라운드에 있는 동안 브라우저가 연결을 끊었어도
        // 요청 자체는 커널 버퍼에서 읽히므로, 응답 전송 성공 여부와 무관하게 로그인을
        // 완료할 수 있어야 한다.
        if !finished {
            finished = true
            onCode(parsed.code, parsed.state)
        }
        respond(conn, status: "200 OK", body: Self.successPage(), contentType: "text/html; charset=utf-8")
        // 응답이 나갈 시간을 준 뒤 리스너를 접는다.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.stop()
        }
    }

    private func respond(_ conn: NWConnection, status: String, body: String,
                         contentType: String = "text/plain; charset=utf-8") {
        let bodyData = Data(body.utf8)
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(bodyData.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        var out = Data(header.utf8)
        out.append(bodyData)
        // 전송 실패(브라우저가 이미 연결을 닫음 등)는 무시한다 — code는 이미 확보했다.
        conn.send(content: out, completion: .contentProcessed { _ in
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
        guard let comp = URLComponents(string: "http://localhost\(target)"),
              comp.path == "/callback"
        else { return nil }
        let items = comp.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty,
              let state = items.first(where: { $0.name == "state" })?.value,
              state == expectedState
        else { return nil }
        return (code, state)
    }

    // MARK: 완료 페이지

    /// 브라우저에 보여줄 최소 HTML(외부 리소스 없음, 앱과 같은 터미널 톤).
    /// 현재 언어를 읽으므로 MainActor에 둔다(호출은 연결 처리 중, 즉 메인 큐에서 일어난다).
    static func successPage() -> String {
        let loc = L10n(lang: currentLang())
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>TokenWatch</title>
        <style>
        body{margin:0;background:#000;color:#D6DBD1;font-family:ui-monospace,Menlo,monospace;
        display:flex;min-height:100vh;align-items:center;justify-content:center;padding:24px}
        .b{border:1px solid #3DD199;padding:28px 24px;max-width:420px;width:100%}
        h1{font-size:17px;color:#3DD199;margin:0 0 12px}
        p{font-size:14px;line-height:1.6;margin:0 0 20px;color:#D6DBD1}
        a{display:block;text-align:center;border:1px solid #3DD199;color:#3DD199;
        text-decoration:none;padding:13px;font-size:14px;font-weight:600}
        </style></head><body><div class="b">
        <h1>\(loc.loopbackDoneTitle)</h1>
        <p>\(loc.loopbackDoneBody)</p>
        <a href="tokenwatch://login-complete">\(loc.loopbackOpenApp)</a>
        </div></body></html>
        """
    }
}
