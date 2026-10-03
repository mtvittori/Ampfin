// AudioStreamCache.swift
// Songs are played from a local file (the equalizer runs on AVAudioEngine), so each
// one has to be downloaded first. They used to be downloaded whole into memory at
// every play, then deleted: a 24-bit/192 kHz FLAC is over 100 MB. Now they are
// downloaded straight to disk, kept in a size-limited cache, and the next song in the
// queue is fetched while the current one plays, so skipping starts at once.

import Foundation

final class AudioStreamCache {
    static let shared = AudioStreamCache()

    /// Oldest songs are removed past this size.
    private let limit: Int64 = 2 * 1024 * 1024 * 1024
    private let directory: URL
    private let queue = DispatchQueue(label: "ampfin.audio-stream-cache")
    /// Downloads in progress, with everyone waiting for each.
    private var inFlight: [String: (task: URLSessionDownloadTask, waiting: [(URL?) -> Void])] = [:]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = caches.appendingPathComponent("AudioStreamCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// One file per song and stream variant (original or a transcoded bitrate).
    func key(itemId: String, url: URL) -> String {
        var hash: UInt64 = 5381
        for byte in (url.query ?? "").utf8 { hash = ((hash &<< 5) &+ hash) &+ UInt64(byte) }
        let ext = url.pathExtension.isEmpty ? "audio" : url.pathExtension
        return "\(itemId)-\(String(format: "%08llx", hash & 0xffffffff)).\(ext)"
    }

    /// The cached file, if the song is already here (and marks it as recently used).
    func cachedFile(forKey key: String) -> URL? {
        let file = directory.appendingPathComponent(key)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return file
    }

    /// Delivers the file on the main queue (nil on failure). A song already being
    /// downloaded is not downloaded twice; asking with `urgent` raises its priority.
    func fetch(_ url: URL, key: String, urgent: Bool, completion: @escaping (URL?) -> Void) {
        if let file = cachedFile(forKey: key) {
            DispatchQueue.main.async { completion(file) }
            return
        }
        queue.async {
            if var entry = self.inFlight[key] {
                entry.waiting.append(completion)
                if urgent { entry.task.priority = URLSessionTask.highPriority }
                self.inFlight[key] = entry
                return
            }
            let task = JellyfinAPIService.urlSession.downloadTask(with: url) { temp, response, error in
                var result: URL?
                if let temp, error == nil,
                   let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    let file = self.directory.appendingPathComponent(key)
                    try? FileManager.default.removeItem(at: file)
                    if (try? FileManager.default.moveItem(at: temp, to: file)) != nil {
                        result = file
                    }
                }
                self.queue.async {
                    let waiting = self.inFlight.removeValue(forKey: key)?.waiting ?? []
                    DispatchQueue.main.async { waiting.forEach { $0(result) } }
                    self.trim()
                }
            }
            task.priority = urgent ? URLSessionTask.highPriority : URLSessionTask.lowPriority
            self.inFlight[key] = (task, [completion])
            task.resume()
        }
    }

    /// Starts downloading in the background without anyone waiting.
    func prefetch(_ url: URL, key: String) {
        guard cachedFile(forKey: key) == nil else { return }
        fetch(url, key: key, urgent: false) { _ in }
    }

    /// Downloads nobody needs any more (the user skipped ahead) give way to the new one.
    func lowerPriority(exceptKey key: String) {
        queue.async {
            for (other, entry) in self.inFlight where other != key {
                entry.task.priority = URLSessionTask.lowPriority
            }
        }
    }

    func size() -> Int64 {
        files().reduce(0) { $0 + $1.size }
    }

    func clear() {
        queue.async {
            for file in self.files() where self.inFlight[file.url.lastPathComponent] == nil {
                try? FileManager.default.removeItem(at: file.url)
            }
        }
    }

    private func trim() {
        var all = files().sorted { $0.date < $1.date }
        var total = all.reduce(0) { $0 + $1.size }
        while total > limit, let oldest = all.first {
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
            all.removeFirst()
        }
    }

    private func files() -> [(url: URL, size: Int64, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
        }
    }
}
