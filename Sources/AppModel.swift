import Foundation
import Security
import UIKit

/// One line of the request history (kept across launches).
struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var kind: String          // "notify", "test" or "clear"
    var title: String
    var body: String
    var ok: Bool
    var error: String?
    var details: String       // the request fields, pretty printed
}

/// Owns the server, the silent-audio keep-alive and the UI state.
/// All @Published mutations happen on the main queue.
final class AppModel: ObservableObject {
    static let port: UInt16 = 8765
    private static let historyKey = "inoty.history"
    private static let historyLimitKey = "inoty.historyLimit"
    static let historyLimitRange = 10...500
    static let defaultHistoryLimit = 100

    @Published var token: String
    @Published var allowNetwork: Bool
    @Published var lanAddress: String?
    @Published var serverStatus = "Starting"
    @Published var audioStatus = "Starting"
    @Published var history: [HistoryEntry]
    @Published var historyLimit: Int

    private let server = LocalServer()
    private let audio = SilentAudio()
    private var started = false
    private var activeObserver: NSObjectProtocol?

    init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "token"), !saved.isEmpty {
            token = saved
        } else {
            let fresh = AppModel.makeToken()
            defaults.set(fresh, forKey: "token")
            token = fresh
        }
        allowNetwork = defaults.bool(forKey: "allowNetwork")
        let savedLimit = defaults.integer(forKey: AppModel.historyLimitKey)
        let limit = AppModel.historyLimitRange.contains(savedLimit) ? savedLimit : AppModel.defaultHistoryLimit
        historyLimit = limit
        history = Array(AppModel.loadHistory().prefix(limit))
    }

    var serverOK: Bool { serverStatus.hasPrefix("Listening") }
    var audioOK: Bool { audioStatus == "Playing silence" }

    var exampleURL: String {
        "http://127.0.0.1:\(AppModel.port)/notify?token=\(token)&title=Hello&body=It%20works"
    }

    /// Address other devices should use, only shown while network access is on.
    var networkURL: String? {
        guard allowNetwork else { return nil }
        return "http://\(lanAddress ?? "<this-device-ip>"):\(AppModel.port)"
    }

    func start() {
        guard !started else { return }
        started = true

        Notifier.shared.setup()
        server.setToken(token)

        server.onState = { [weak self] status in
            DispatchQueue.main.async { self?.serverStatus = status }
        }
        server.onNotify = { [weak self] spec, done in
            Notifier.shared.post(spec) { identifier, error in
                DispatchQueue.main.async {
                    self?.record(kind: "notify", title: spec.title, body: spec.body,
                                 error: error, details: spec.details)
                }
                done(identifier, error)
            }
        }
        server.onRejected = { [weak self] details, error in
            DispatchQueue.main.async {
                self?.record(kind: "notify", title: "Rejected request", body: "",
                             error: error, details: details)
            }
        }
        server.onClear = { [weak self] id in
            Notifier.shared.clear(id: id)
            DispatchQueue.main.async {
                self?.record(kind: "clear", title: id.map { "Clear \($0)" } ?? "Clear all", body: "",
                             error: nil, details: "")
            }
        }
        audio.onState = { [weak self] status in
            DispatchQueue.main.async { self?.audioStatus = status }
        }

        audio.start()
        refreshLAN()
        server.start(port: AppModel.port, allowNetwork: allowNetwork)

        // Recover if iOS killed the listener or the audio session while we were away.
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.audio.ensurePlaying()
            self.refreshLAN()
            if !self.serverOK {
                self.server.start(port: AppModel.port, allowNetwork: self.allowNetwork)
            }
        }
    }

    func setAllowNetwork(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "allowNetwork")
        allowNetwork = enabled
        refreshLAN()
        serverStatus = "Restarting"
        server.start(port: AppModel.port, allowNetwork: enabled)
    }

    func regenerateToken() {
        let fresh = AppModel.makeToken()
        UserDefaults.standard.set(fresh, forKey: "token")
        token = fresh
        server.setToken(fresh)
    }

    func sendTest() {
        var spec = NotificationSpec()
        spec.title = "iNoty"
        spec.body = "Test notification"
        Notifier.shared.post(spec) { [weak self] _, error in
            DispatchQueue.main.async {
                self?.record(kind: "test", title: spec.title, body: spec.body, error: error, details: "")
            }
        }
    }

    func clearHistory() {
        history = []
        saveHistory()
    }

    /// Changes how many requests are kept; older ones beyond the new limit are deleted.
    func setHistoryLimit(_ value: Int) {
        let limit = min(max(value, AppModel.historyLimitRange.lowerBound), AppModel.historyLimitRange.upperBound)
        UserDefaults.standard.set(limit, forKey: AppModel.historyLimitKey)
        historyLimit = limit
        if history.count > limit {
            history.removeLast(history.count - limit)
            saveHistory()
        }
    }

    // MARK: History

    /// Must be called on the main queue.
    private func record(kind: String, title: String, body: String, error: String?, details: String) {
        let entry = HistoryEntry(
            kind: kind,
            title: String(title.prefix(200)),
            body: String(body.prefix(500)),
            ok: error == nil,
            error: error,
            details: details
        )
        history.insert(entry, at: 0)
        if history.count > historyLimit {
            history.removeLast(history.count - historyLimit)
        }
        saveHistory()
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: AppModel.historyKey)
        }
    }

    private static func loadHistory() -> [HistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let list = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return [] }
        return list
    }

    // MARK: Helpers

    private func refreshLAN() {
        lanAddress = LocalIP.ipv4()
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
