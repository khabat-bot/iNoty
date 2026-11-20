import Foundation
import Security
import UIKit

/// Owns the server, the silent-audio keep-alive and the UI state.
/// All @Published mutations happen on the main queue.
final class AppModel: ObservableObject {
    static let port: UInt16 = 8765

    @Published var token: String
    @Published var serverStatus = "Stopped"
    @Published var audioStatus = "Stopped"
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
    }

    var exampleURL: String {
        "http://127.0.0.1:\(AppModel.port)/notify?token=\(token)&title=Hello&body=It%20works"
    }

    func start() {
        guard !started else { return }
        started = true

        Notifier.shared.setup()
        server.setToken(token)

        server.onState = { [weak self] status in
            DispatchQueue.main.async { self?.serverStatus = status }
        }
        server.onNotify = { [weak self] title, body, subtitle in
            Notifier.shared.post(title: title, body: body, subtitle: subtitle)
            DispatchQueue.main.async { self?.addLog(title) }
        }
        audio.onState = { [weak self] status in
            DispatchQueue.main.async { self?.audioStatus = status }
        }

        audio.start()
        server.start(port: AppModel.port)

        // Recover if iOS killed the listener or the audio session while we were away.
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.audio.ensurePlaying()
            if !self.serverStatus.hasPrefix("Listening") {
                self.server.start(port: AppModel.port)
            }
        }
    }

    func regenerateToken() {
        let fresh = AppModel.makeToken()
        UserDefaults.standard.set(fresh, forKey: "token")
        token = fresh
        server.setToken(fresh)
    }

    func sendTest() {
        Notifier.shared.post(title: "iNoty", body: "Test notification", subtitle: nil)
        addLog("Test notification")
    }

    private func addLog(_ title: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.insert("\(f.string(from: Date()))  \(title)", at: 0)
        if log.count > 30 { log.removeLast(log.count - 30) }
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
