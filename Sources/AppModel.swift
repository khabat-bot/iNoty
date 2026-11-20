import Foundation
import Security
import UIKit

/// Owns the server, the silent-audio keep-alive and the UI state.
/// All @Published mutations happen on the main queue.
final class AppModel: ObservableObject {
    static let port: UInt16 = 8765

    @Published var token: String
    @Published var allowNetwork: Bool
    @Published var lanAddress: String?
    @Published var serverStatus = "Starting"
    @Published var audioStatus = "Starting"
    @Published var log: [String] = []

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
                let label = spec.title.isEmpty ? spec.body : spec.title
                DispatchQueue.main.async {
                    self?.addLog(error == nil ? label : "Failed: \(label)")
                }
                done(identifier, error)
            }
        }
        server.onClear = { [weak self] id in
            Notifier.shared.clear(id: id)
            DispatchQueue.main.async { self?.addLog(id.map { "Cleared \($0)" } ?? "Cleared all") }
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
                self?.addLog(error == nil ? "Test notification" : "Test failed: \(error ?? "")")
            }
        }
    }

    private func refreshLAN() {
        lanAddress = LocalIP.ipv4()
    }

    private func addLog(_ text: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.insert("\(f.string(from: Date()))  \(String(text.prefix(80)))", at: 0)
        if log.count > 30 { log.removeLast(log.count - 30) }
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
