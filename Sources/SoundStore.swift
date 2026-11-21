import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SoundError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Custom notification sounds the person added inside the app.
/// Files live in Library/Sounds as .caf, which is where iOS looks for notification sounds.
enum SoundStore {
    static let reserved = ["default", "none", "ringtone"]
    static let maxSeconds = 30.0

    static var directory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Sounds", isDirectory: true)
    }

    /// Names (no extension) of the installed sounds, sorted.
    static func list() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files
            .filter { $0.lowercased().hasSuffix(".caf") && !$0.hasPrefix(".") }
            .map { String($0.dropLast(4)) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// File name ("name.caf") for a requested sound name, matched case-insensitively.
    /// The name may be given with or without ".caf". Returns nil if no such sound is installed.
    static func fileName(for requested: String) -> String? {
        var wanted = requested.trimmingCharacters(in: .whitespaces).lowercased()
        if wanted.hasSuffix(".caf") { wanted = String(wanted.dropLast(4)) }
        guard !wanted.isEmpty else { return nil }
        for name in list() where name.lowercased() == wanted {
            return name + ".caf"
        }
        return nil
    }

    static func url(forName name: String) -> URL {
        directory.appendingPathComponent(name + ".caf")
    }

    static func delete(name: String) {
        try? FileManager.default.removeItem(at: url(forName: name))
    }

    /// Converts any audio file iOS can read (mp3, m4a, wav, aiff, caf...) to a 16-bit PCM .caf
    /// in Library/Sounds and returns the sound's name. Throws if it is empty or longer than 30 s.
    static func importFile(from source: URL) throws -> String {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw SoundError("not an audio file iOS can read")
        }

        let format = input.processingFormat
        let seconds = Double(input.length) / format.sampleRate
        guard seconds > 0 else { throw SoundError("the file is empty") }
        guard seconds <= maxSeconds else {
            throw SoundError("it is \(Int(seconds.rounded())) s long; iOS only plays notification sounds up to 30 s")
        }

        let name = sanitize(source.deletingPathExtension().lastPathComponent)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("inoty-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: temp) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        do {
            let output = try AVAudioFile(
                forWriting: temp,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32768) else {
                throw SoundError("could not read the file")
            }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
        } catch let error as SoundError {
            throw error
        } catch {
            throw SoundError("conversion failed: \(error.localizedDescription)")
        }

        let fm = FileManager.default
        let destination = url(forName: name)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: temp, to: destination)
        } catch {
            throw SoundError("could not save it: \(error.localizedDescription)")
        }
        return name
    }

    /// Letters, digits, dot, dash and underscore only, so the name is easy to type in a request.
    private static func sanitize(_ raw: String) -> String {
        var out = ""
        for ch in raw.trimmingCharacters(in: .whitespaces) {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "-" || ch == "_") {
                out.append(ch)
            } else if ch == " " {
                out.append("-")
            } else {
                out.append("_")
            }
        }
        if out.isEmpty { out = "sound" }
        if reserved.contains(out.lowercased()) { out = "custom-" + out }
        return String(out.prefix(60))
    }
}

/// System file picker restricted to audio files. Picked files are copied, so no extra access is needed.
struct SoundPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}
