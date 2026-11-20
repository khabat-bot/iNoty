import Foundation
import Network

// MARK: - Minimal HTTP request parsing

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    enum ParseResult {
        case incomplete
        case bad
        case ok(HTTPRequest)
    }

    static func parse(_ data: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else { return .incomplete }
        guard let head = String(data: data.subdata(in: data.startIndex..<range.lowerBound), encoding: .utf8) else {
            return .bad
        }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .bad }

        var headers: [String: String] = [:]
        for line in lines {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= 8192 else { return .bad }

        let bodyStart = range.upperBound
        if data.endIndex - bodyStart < length { return .incomplete }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))

        guard let comps = URLComponents(string: "http://localhost" + String(requestLine[1])) else { return .bad }
        var query: [String: String] = [:]
        for item in comps.queryItems ?? [] { query[item.name] = item.value ?? "" }

        return .ok(HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: comps.path,
            query: query,
            headers: headers,
            body: body
        ))
    }
}

// MARK: - Loopback-only server

/// Tiny HTTP server bound to 127.0.0.1 only. Nothing on the local network can reach it.
/// Every request except /health must carry the secret token.
final class LocalServer {
    var onState: (String) -> Void = { _ in }
    var onNotify: (_ title: String, _ body: String, _ subtitle: String?) -> Void = { _, _, _ in }

    private let queue = DispatchQueue(label: "inoty.server")
    private let lock = NSLock()
    private var token = ""
    private var listener: NWListener?

    func setToken(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        token = value
    }

    private func currentToken() -> String {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    func start(port: UInt16) {
        queue.async { [weak self] in self?.startLocked(port: port) }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
        }
    }

    private func startLocked(port: UInt16) {
        listener?.cancel()
        listener = nil

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onState("Invalid port")
            return
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)

        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            l.stateUpdateHandler = { [weak self, weak l] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.onState("Listening on 127.0.0.1:\(port)")
                case .waiting(let error):
                    self.onState("Waiting: \(error.localizedDescription)")
                case .failed(let error):
                    self.onState("Failed: \(error.localizedDescription). Retrying...")
                    l?.cancel()
                    self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                        self?.startLocked(port: port)
                    }
                default:
                    break
                }
            }
            listener = l
            l.start(queue: queue)
        } catch {
            onState("Could not start: \(error.localizedDescription)")
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.startLocked(port: port)
            }
        }
    }

    // MARK: Connections

    private func handle(_ connection: NWConnection) {
        // Defense in depth: drop anything that is not coming from loopback.
        if case let .hostPort(host, _) = connection.endpoint {
            var isLoopback = false
            switch host {
            case .ipv4(let a): isLoopback = a.isLoopback
            case .ipv6(let a): isLoopback = a.isLoopback
            default: break
            }
            if !isLoopback {
                connection.cancel()
                return
            }
        }

        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self = self else { connection.cancel(); return }

            var buf = buffer
            if let data = data { buf.append(data) }
            if buf.count > 16384 {
                self.respond(connection, 413, ["ok": false, "error": "payload too large"])
                return
            }

            switch HTTPRequest.parse(buf) {
            case .ok(let request):
                self.route(request, on: connection)
            case .bad:
                self.respond(connection, 400, ["ok": false, "error": "bad request"])
            case .incomplete:
                if error != nil || isComplete {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buf)
                }
            }
        }
    }

    // MARK: Routing

    private func route(_ req: HTTPRequest, on c: NWConnection) {
        // Reject requests whose Host header is not localhost / 127.0.0.1 (DNS rebinding guard).
        guard hostAllowed(req) else {
            respond(c, 403, ["ok": false, "error": "forbidden host"])
            return
        }

        if req.path == "/health" {
            respond(c, 200, ["ok": true])
            return
        }

        guard req.path == "/notify" else {
            respond(c, 404, ["ok": false, "error": "not found"])
            return
        }
        guard req.method == "GET" || req.method == "POST" else {
            respond(c, 405, ["ok": false, "error": "method not allowed"])
            return
        }
        guard tokenValid(req) else {
            respond(c, 401, ["ok": false, "error": "invalid token"])
            return
        }

        var title = req.query["title"] ?? ""
        var body = req.query["body"] ?? req.query["message"] ?? ""
        var subtitle = req.query["subtitle"]

        if req.method == "POST", !req.body.isEmpty {
            if let obj = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] {
                if let t = obj["title"] as? String { title = t }
                if let b = (obj["body"] as? String) ?? (obj["message"] as? String) { body = b }
                if let s = obj["subtitle"] as? String { subtitle = s }
            } else if let text = String(data: req.body, encoding: .utf8) {
                // Plain-text POST: the whole body is the message.
                body = text
            }
        }

        guard !title.isEmpty || !body.isEmpty else {
            respond(c, 400, ["ok": false, "error": "need title or body"])
            return
        }

        onNotify(
            title.isEmpty ? "iNoty" : String(title.prefix(200)),
            String(body.prefix(1000)),
            subtitle.map { String($0.prefix(200)) }
        )
        respond(c, 200, ["ok": true])
    }

    private func hostAllowed(_ req: HTTPRequest) -> Bool {
        guard let host = req.headers["host"]?.lowercased() else { return false }
        let name = host.split(separator: ":").first.map(String.init) ?? host
        return name == "127.0.0.1" || name == "localhost"
    }

    private func tokenValid(_ req: HTTPRequest) -> Bool {
        let expected = currentToken()
        guard !expected.isEmpty else { return false }

        var supplied = req.headers["x-token"] ?? req.query["token"] ?? ""
        if supplied.isEmpty, let auth = req.headers["authorization"], auth.lowercased().hasPrefix("bearer ") {
            supplied = String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        return constantTimeEquals(supplied, expected)
    }

    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    // MARK: Responses

    private func respond(_ c: NWConnection, _ status: Int, _ json: [String: Any]) {
        let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                       404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large"]
        let payload = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let head = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(payload.count)\r\n"
            + "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(payload)
        c.send(content: out, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            c.cancel()
        })
    }
}
