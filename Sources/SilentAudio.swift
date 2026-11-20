import AVFoundation
import Foundation

/// Loops a silent audio clip so iOS keeps the app alive in the background
/// (needs the "audio" entry in UIBackgroundModes, set in Info.plist).
final class SilentAudio {
    var onState: (String) -> Void = { _ in }

    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []

    func start() {
        configureSession()
        play()

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            if type == .ended {
                self?.configureSession()
                self?.play()
            } else {
                self?.onState("Interrupted")
            }
        })
        observers.append(nc.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.player = nil
            self?.configureSession()
            self?.play()
        })
    }

    func ensurePlaying() {
        if player?.isPlaying != true {
            configureSession()
            play()
        }
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            onState("Session error: \(error.localizedDescription)")
        }
    }

    private func play() {
        do {
            if player == nil {
                let p = try AVAudioPlayer(data: SilentAudio.silentWAV(), fileTypeHint: AVFileType.wav.rawValue)
                p.numberOfLoops = -1
                p.prepareToPlay()
                player = p
            }
            if player?.play() == true {
                onState("Playing silence")
            } else {
                onState("Could not start playback")
            }
        } catch {
            onState("Audio error: \(error.localizedDescription)")
        }
    }

    /// One second of 8 kHz 16-bit mono silence, as an in-memory WAV file.
    private static func silentWAV() -> Data {
        let sampleRate: UInt32 = 8000
        let dataSize: UInt32 = sampleRate * 2   // 1 second, 2 bytes per sample
        var d = Data()

        func u32(_ v: UInt32) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
        }
        func u16(_ v: UInt16) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
        }

        d.append(Data("RIFF".utf8)); u32(36 + dataSize)
        d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(dataSize)
        d.append(Data(count: Int(dataSize)))
        return d
    }
}
