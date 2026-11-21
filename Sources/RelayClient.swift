import Foundation

/// Listens to one topic on an ntfy server (https://ntfy.sh by default) and hands every message
/// to `onMessage`. The phone only makes an outgoing HTTPS connection, so this works on any
/// network (cellular, other Wi-Fi) without opening a port.
///
/// Messages that arrive while the phone is offline are fetched on reconnect (the server keeps
/// them for a while, 12 hours on ntfy.sh by default) using the id of the last message seen.
final class RelayClient: NSObject, URLSessionDataDelegate {
    /// Human-readable connection state. Called on the relay queue.
    var onState: (String) -> Void = { _ in }
    /// One ntfy "message" event, as a dictionary. Called on the relay queue.
    var onMessage: (_ event: [String: Any]) -> Void = { _ in }

    private static let lastIDKey = "inoty.relay.lastID"
    private static let sinceKey = "inoty.relay.since"

    private let queue = DispatchQueue(label: "inoty.relay")

    private lazy var session: URLSession = {
        let operations = OperationQueue()
        operations.maxConcurrentOperationCount = 1
        operations.underlyingQueue = queue

        let config = URLSessionConfiguration.default
        // Longest silence tolerated. The server sends keepalives much more often than this.
        config.timeoutIntervalForRequest = 150
        config.timeoutIntervalForResource = 24 * 3600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: operations)
    }()

    // Everything below is only touched on `queue`.
    private var server = ""
    private var topic = ""
    private var running = false
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var connected = false
    private var failures = 0
    private var retryWork: DispatchWorkItem?

    // MARK: Control

    /// Forget where we were, so only messages sent from now on are delivered.
    /// Call this whenever the topic or server changes or the relay is switched on.
    static func resetCursor() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: lastIDKey)
        defaults.set(Int(Date().timeIntervalSince1970), forKey: sinceKey)
    }

    private static func cursor() -> String {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: lastIDKey), !id.isEmpty { return id }
        let since = defaults.integer(forKey: sinceKey)
        return String(since > 0 ? since : Int(Date().timeIntervalSince1970))
    }

    func start(server: String, topic: String) {
        queue.async {
            self.stopLocked()
            self.server = server
            self.topic = topic
            self.running = true
            self.failures = 0
            self.connectLocked()
        }
    }

    func stop() {
        queue.async {
            self.stopLocked()
            self.onState("Off")
        }
    }

    /// Opens a fresh connection (used when the app comes back to the foreground, since iOS may
    /// have silently dropped the old one). Nothing is delivered twice.
    func reconnect() {
        queue.async {
            guard self.running else { return }
            self.connectLocked()
        }
    }

    // MARK: Connection

    private func stopLocked() {
        running = false
        retryWork?.cancel()
        retryWork = nil
        task?.cancel()
        task = nil
        connected = false
        buffer.removeAll()
    }

    private func connectLocked() {
        retryWork?.cancel()
        retryWork = nil
        task?.cancel()
        task = nil
        buffer.removeAll()
        connected = false

        var components = URLComponents(string: server + "/" + topic + "/json")
        components?.queryItems = [URLQueryItem(name: "since", value: RelayClient.cursor())]
        guard let url = components?.url else {
            onState("Invalid relay address")
            return
        }

        onState(failures == 0 ? "Connecting..." : "Reconnecting...")
        var request = URLRequest(url: url)
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        let newTask = session.dataTask(with: request)
        task = newTask
        newTask.resume()
    }

    private func markConnected() {
        failures = 0
        if !connected {
            connected = true
            onState("Connected")
        }
    }

    private func handleFailure(_ reason: String) {
        task?.cancel()
        task = nil
        connected = false
        guard running else { return }

        failures += 1
        let delay = min(60.0, pow(2.0, Double(min(failures, 6))))   // 2, 4, 8, 16, 32, 60 seconds
        onState("Disconnected (\(reason)). Retrying in \(Int(delay)) s")
        let work = DispatchWorkItem { [weak self] in self?.connectLocked() }
        retryWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Stream parsing

    private func handleLine(_ line: Data) {
        guard !line.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let event = object["event"] as? String
        else { return }

        switch event {
        case "open", "keepalive":
            markConnected()
        case "message":
            markConnected()
            if let id = object["id"] as? String {
                UserDefaults.standard.set(id, forKey: RelayClient.lastIDKey)
            }
            onMessage(object)
        default:
            break   // message_delete, message_clear, poll_request: nothing to do
        }
    }

    // MARK: URLSessionDataDelegate (runs on `queue`)

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard dataTask === task else {
            completionHandler(.cancel)
            return
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            handleFailure("server answered HTTP \(http.statusCode)")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            handleLine(line)
        }
        if buffer.count > 1_000_000 { buffer.removeAll() }   // a line that never ends
    }

    func urlSession(_ session: URLSession, task finished: URLSessionTask, didCompleteWithError error: Error?) {
        guard finished === task else { return }   // an old connection we already replaced
        let reason = error.map { String(($0 as NSError).localizedDescription.prefix(60)) } ?? "connection closed"
        handleFailure(reason)
    }
}
