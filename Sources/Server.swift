import Foundation
import Network

// MARK: - Minimal HTTP request parsing

struct HTTPRequest {
    static let maxBody = 2_000_000

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
        guard length >= 0, length <= maxBody else { return .bad }

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

// MARK: - Server

/// Tiny HTTP server. By default it is bound to 127.0.0.1 only, so nothing on the network can
/// reach it. With "allow network" on it listens on every interface but still only accepts
/// connections from private/loopback addresses. Every request except /health needs the token.
final class LocalServer {
    var onState: (String) -> Void = { _ in }
    var onNotify: (_ spec: NotificationSpec, _ done: @escaping (_ identifier: String, _ error: String?) -> Void) -> Void = { _, done in
        done("", "server not ready")
    }
    var onClear: (_ id: String?) -> Void = { _ in }

    private let queue = DispatchQueue(label: "inoty.server")
    private let lock = NSLock()
    private var token = ""
    private var listener: NWListener?
    private var networkAllowed = false   // only touched on `queue`

    func setToken(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        token = value
    }

    private func currentToken() -> String {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    func start(port: UInt16, allowNetwork: Bool) {
        queue.async { [weak self] in self?.startLocked(port: port, allowNetwork: allowNetwork) }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
        }
    }

    private func startLocked(port: UInt16, allowNetwork: Bool) {
        listener?.cancel()
        listener = nil
        networkAllowed = allowNetwork

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onState("Invalid port")
            return
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            let l: NWListener
            if allowNetwork {
                l = try NWListener(using: params, on: nwPort)
            } else {
                params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
                l = try NWListener(using: params)
            }
            l.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            l.stateUpdateHandler = { [weak self, weak l] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.onState(allowNetwork
                        ? "Listening on all interfaces :\(port) (private networks only)"
                        : "Listening on 127.0.0.1:\(port)")
                case .waiting(let error):
                    self.onState("Waiting: \(error.localizedDescription)")
                case .failed(let error):
                    self.onState("Failed: \(error.localizedDescription). Retrying...")
                    l?.cancel()
                    self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                        self?.startLocked(port: port, allowNetwork: allowNetwork)
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
                self?.startLocked(port: port, allowNetwork: allowNetwork)
            }
        }
    }

    // MARK: Connections

    private func handle(_ connection: NWConnection) {
        // Loopback mode: only this phone. Network mode: loopback plus private ranges
        // (never public addresses, e.g. a global IPv6 address on cellular).
        guard case let .hostPort(host, _) = connection.endpoint, isAllowedRemote(host) else {
            connection.cancel()
            return
        }

        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 30) { connection.cancel() }
        receive(connection, buffer: Data())
    }

    private func isAllowedRemote(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let a):
            return ipv4Allowed(a)
        case .ipv6(let a):
            if a.isIPv4Mapped, let v4 = a.asIPv4 { return ipv4Allowed(v4) }
            if a.isLoopback { return true }
            guard networkAllowed else { return false }
            let b = [UInt8](a.rawValue)
            guard b.count == 16 else { return false }
            let uniqueLocal = (b[0] & 0xFE) == 0xFC            // fc00::/7
            let linkLocal = b[0] == 0xFE && (b[1] & 0xC0) == 0x80   // fe80::/10
            return uniqueLocal || linkLocal
        default:
            return false
        }
    }

    private func ipv4Allowed(_ a: IPv4Address) -> Bool {
        if a.isLoopback { return true }
        guard networkAllowed else { return false }
        let b = [UInt8](a.rawValue)
        guard b.count == 4 else { return false }
        if b[0] == 10 { return true }                                   // 10.0.0.0/8
        if b[0] == 172 && (16...31).contains(b[1]) { return true }       // 172.16.0.0/12
        if b[0] == 192 && b[1] == 168 { return true }                    // 192.168.0.0/16
        if b[0] == 169 && b[1] == 254 { return true }                    // link-local
        if b[0] == 100 && (64...127).contains(b[1]) { return true }      // 100.64.0.0/10 (CGNAT, Tailscale)
        return false
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { connection.cancel(); return }

            var buf = buffer
            if let data = data { buf.append(data) }
            if buf.count > HTTPRequest.maxBody + 16384 {
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
        // Loopback mode also rejects any Host header other than localhost / 127.0.0.1
        // (DNS rebinding guard). In network mode the token is the protection.
        if !networkAllowed && !hostAllowed(req) {
            respond(c, 403, ["ok": false, "error": "forbidden host"])
            return
        }

        if req.path == "/health" {
            respond(c, 200, ["ok": true])
            return
        }

        switch req.path {
        case "/notify":
            guard req.method == "GET" || req.method == "POST" else {
                respond(c, 405, ["ok": false, "error": "method not allowed"])
                return
            }
            guard tokenValid(req) else {
                respond(c, 401, ["ok": false, "error": "invalid token"])
                return
            }
            handleNotify(req, on: c)

        case "/clear":
            guard ["GET", "POST", "DELETE"].contains(req.method) else {
                respond(c, 405, ["ok": false, "error": "method not allowed"])
                return
            }
            guard tokenValid(req) else {
                respond(c, 401, ["ok": false, "error": "invalid token"])
                return
            }
            handleClear(req, on: c)

        default:
            respond(c, 404, ["ok": false, "error": "not found"])
        }
    }

    private func handleNotify(_ req: HTTPRequest, on c: NWConnection) {
        let spec: NotificationSpec
        do {
            spec = try NotificationSpec.from(try payload(for: req))
        } catch let e as SpecError {
            respond(c, 400, ["ok": false, "error": e.description])
            return
        } catch {
            respond(c, 400, ["ok": false, "error": "bad request"])
            return
        }

        onNotify(spec) { [weak self] identifier, error in
            if let error = error {
                self?.respond(c, 500, ["ok": false, "id": identifier, "error": error])
            } else {
                self?.respond(c, 200, ["ok": true, "id": identifier])
            }
        }
    }

    private func handleClear(_ req: HTTPRequest, on c: NWConnection) {
        let raw: [String: Any]
        do {
            raw = try payload(for: req)
        } catch let e as SpecError {
            respond(c, 400, ["ok": false, "error": e.description])
            return
        } catch {
            respond(c, 400, ["ok": false, "error": "bad request"])
            return
        }
        let id = (raw["id"] as? String) ?? (raw["identifier"] as? String)
        onClear(id)
        respond(c, 200, ["ok": true])
    }

    /// Query parameters first, then a JSON body on top (JSON wins). A non-JSON POST body is the message.
    private func payload(for req: HTTPRequest) throws -> [String: Any] {
        var raw: [String: Any] = [:]
        for (k, v) in req.query where k != "token" { raw[k] = v }

        if req.method == "POST", !req.body.isEmpty {
            let declaredJSON = (req.headers["content-type"] ?? "").lowercased().contains("json")
            if let obj = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] {
                for (k, v) in obj { raw[k] = v }
            } else if declaredJSON {
                throw SpecError("body is not a valid JSON object")
            } else if let text = String(data: req.body, encoding: .utf8) {
                raw["body"] = text
            }
        }
        return raw
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
                       404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large",
                       500: "Internal Server Error"]
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
