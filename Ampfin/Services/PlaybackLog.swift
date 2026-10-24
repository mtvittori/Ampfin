import Foundation
import AVFoundation

/// A small log on disk for playback problems: `print` is lost on a phone, and a song that
/// fails once in a while can only be explained afterwards. Lines go to
/// Application Support/Ampfin/playback.log; past 512 KB the oldest half is dropped.
enum PlaybackLog {
    private static let maxBytes: UInt64 = 512 * 1024
    /// All file work happens here, so callers (often the main thread) never wait for the disk.
    private static let queue = DispatchQueue(label: "ampfin.playbacklog", qos: .utility)
    /// Only used on `queue`: DateFormatter is not thread-safe.
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static let fileURL: URL = {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("Ampfin", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("playback.log")
    }()

    static func log(_ message: String) {
        let now = Date()
        print(message)
        queue.async {
            let line = "\(formatter.string(from: now)) \(message)\n"
            append(Data(line.utf8))
        }
    }

    private static func append(_ data: Data) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            if size > maxBytes {
                trim(handle, size: size)
                try handle.seekToEnd()
            }
            try handle.write(contentsOf: data)
        } catch {
            print("PlaybackLog: write failed – \(error)")
        }
    }

    /// Keeps the last half, starting at a line boundary.
    private static func trim(_ handle: FileHandle, size: UInt64) {
        do {
            try handle.seek(toOffset: size / 2)
            guard var tail = try handle.readToEnd() else { return }
            if let newline = tail.firstIndex(of: 0x0A) { tail = tail.suffix(from: tail.index(after: newline)) }
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: tail)
        } catch {
            print("PlaybackLog: trim failed – \(error)")
        }
    }

    // MARK: - Descriptions

    /// "48000Hz 2ch interleaved=false float32".
    static func describe(_ format: AVAudioFormat?) -> String {
        guard let format else { return "none" }
        let common: String
        switch format.commonFormat {
        case .pcmFormatFloat32: common = "float32"
        case .pcmFormatFloat64: common = "float64"
        case .pcmFormatInt16: common = "int16"
        case .pcmFormatInt32: common = "int32"
        default: common = "other"
        }
        return "\(Int(format.sampleRate))Hz \(format.channelCount)ch interleaved=\(format.isInterleaved) \(common)"
    }

    /// The output route and the session rate, which is what changes between a good and a bad hour.
    static func routeDescription() -> String {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue) \u{27}\($0.portName)\u{27}" }
        return "route=[\(outputs.joined(separator: ", "))] sessionRate=\(Int(session.sampleRate))Hz"
        #else
        return "route=default output"
        #endif
    }

    /// "Domain(code)" of an error, for the open attempts.
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain)(\(ns.code))"
    }
}
