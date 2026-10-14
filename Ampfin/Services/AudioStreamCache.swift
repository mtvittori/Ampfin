// AudioStreamCache.swift
// Songs are played from a local file (the equalizer runs on AVAudioEngine), so each
// one has to be downloaded first. They used to be downloaded whole into memory at
// every play, then deleted: a 24-bit/192 kHz FLAC is over 100 MB. Now they are
// downloaded straight to disk, kept in a size-limited cache, and the next song in the
// queue is fetched while the current one plays, so skipping starts at once.

import Foundation

/// What Settings → Cache decides about keeping songs (all in UserDefaults, so they travel in the backup).
enum SongCacheSettings {
    static let limitKey = "songCacheLimitGB"
    static let windowKey = "songCacheWindowDays"
    static let minPlaysKey = "songCacheMinPlays"
    static let defaultLimitGB = 2
    static let defaultWindowDays = 30
    static let defaultMinPlays = 2
    static let limitChoices = [1, 2, 5, 10, 20]
    /// 0 = never: only the size limit applies.
    static let windowChoices = [7, 30, 90, 0]

    static func windowLabel(_ days: Int) -> String {
        switch days {
        case 7: return "Una settimana"
        case 30: return "Un mese"
        case 90: return "Tre mesi"
        default: return "Mai"
        }
    }

    static var current: SongCachePolicy {
        let defaults = UserDefaults.standard
        func int(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: key) as? Int ?? fallback }
        return SongCachePolicy(limitBytes: Int64(max(1, int(limitKey, defaultLimitGB))) * 1024 * 1024 * 1024,
                               windowDays: max(0, int(windowKey, defaultWindowDays)),
                               minPlays: max(1, int(minPlaysKey, defaultMinPlays)))
    }
}

struct SongCachePolicy: Equatable {
    var limitBytes: Int64
    var windowDays: Int
    var minPlays: Int
}

/// A cached file as the eviction sees it.
struct SongCacheEntry: Equatable {
    var key: String
    var size: Int64
    var added: Date
    var plays: [Date]
}

enum SongCacheEviction {
    /// Play dates older than this are forgotten (the longest period on offer).
    static let playHistoryDays = 90

    /// Pure decision, so it can be tested: the keys to delete.
    /// 1. With a period: files in the cache for at least that long and played fewer than
    ///    `minPlays` times within it go. A newer file is safe until a full period has passed.
    /// 2. Still over the size limit: fewest plays in the period first, then the one
    ///    played (or added) longest ago, until it fits. `protected` files are never chosen.
    static func keysToRemove(entries: [SongCacheEntry], protected: Set<String>,
                             now: Date, policy: SongCachePolicy) -> [String] {
        let day: TimeInterval = 86_400
        // With "never" the plays still rank the files, over the whole history.
        let window = Double(policy.windowDays > 0 ? policy.windowDays : playHistoryDays) * day
        let since = now.addingTimeInterval(-window)
        func playsInWindow(_ entry: SongCacheEntry) -> Int { entry.plays.filter { $0 >= since }.count }

        var removed: [String] = []
        var kept: [SongCacheEntry] = []
        for entry in entries {
            let expired = policy.windowDays > 0
                && now.timeIntervalSince(entry.added) >= window
                && playsInWindow(entry) < policy.minPlays
            if expired && !protected.contains(entry.key) {
                removed.append(entry.key)
            } else {
                kept.append(entry)
            }
        }

        var total = kept.reduce(0) { $0 + $1.size }
        guard total > policy.limitBytes else { return removed }
        let candidates = kept.filter { !protected.contains($0.key) }.map {
            (entry: $0, plays: playsInWindow($0), last: $0.plays.max() ?? $0.added)
        }.sorted {
            $0.plays != $1.plays ? $0.plays < $1.plays : $0.last < $1.last
        }
        for candidate in candidates where total > policy.limitBytes {
            removed.append(candidate.entry.key)
            total -= candidate.entry.size
        }
        return removed
    }
}

final class AudioStreamCache {
    static let shared = AudioStreamCache()

    private struct IndexEntry: Codable {
        var added: Date
        var plays: [Date]
    }

    private let directory: URL
    private let indexURL: URL
    private let queue = DispatchQueue(label: "ampfin.audio-stream-cache")
    /// Downloads in progress, with everyone waiting for each.
    private var inFlight: [String: (task: URLSessionDownloadTask, waiting: [(URL?) -> Void])] = [:]
    /// The song playing and the one prefetched after it are never evicted (even with 0
    /// plays, they are about to be heard). Touched only on `queue`.
    private var currentKey: String?
    private var prefetchedKey: String?
    /// Added date and play dates per file, loaded on first use. Touched only on `queue`.
    private var index: [String: IndexEntry]?
    private var saveScheduled = false
    private var settingsTrim: DispatchWorkItem?

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = caches.appendingPathComponent("AudioStreamCache", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
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

    /// Whether the song is here, without marking it as used (for counting many).
    func containsFile(forKey key: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(key).path)
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
        queue.async { self.prefetchedKey = key }
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

    /// Total size and number of songs, for Settings.
    func usage() -> (bytes: Int64, count: Int) {
        let all = files()
        return (all.reduce(0) { $0 + $1.size }, all.count)
    }

    func clear() {
        queue.async {
            for file in self.files() where self.inFlight[file.url.lastPathComponent] == nil {
                try? FileManager.default.removeItem(at: file.url)
            }
            self.index = [:]
            self.scheduleSave()
        }
    }

    // MARK: - Plays and eviction

    /// A song was requested for real playback (not prefetch, not the DR scan): it counts
    /// as a listen and is protected from eviction while it plays.
    func recordPlay(forKey key: String) {
        queue.async {
            self.currentKey = key
            var index = self.loadedIndex()
            index[key, default: IndexEntry(added: Date(), plays: [])].plays.append(Date())
            self.index = index
            self.scheduleSave()
        }
    }

    /// Applies the settings a moment after the last change: tapping a Stepper from 1 to 5
    /// must not delete files at 3 and 4 along the way (deleting can't be undone).
    func settingsChanged() {
        queue.async {
            self.settingsTrim?.cancel()
            let work = DispatchWorkItem { self.trim() }
            self.settingsTrim = work
            self.queue.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }

    /// Once at launch, off the critical path: the cache may have grown past new settings
    /// or songs may have expired since the last run.
    func trimSoon() {
        queue.asyncAfter(deadline: .now() + 5) { self.trim() }
    }

    /// Must run on `queue`.
    private func trim() {
        var index = loadedIndex()
        let now = Date()
        let present = files()
        let names = Set(present.map { $0.url.lastPathComponent })

        // A file without an entry predates the log: its age is its file date, no plays.
        for file in present where index[file.url.lastPathComponent] == nil {
            index[file.url.lastPathComponent] = IndexEntry(added: file.date, plays: [])
        }
        // Entries of deleted files go, except for a song still downloading (it may already have plays).
        for key in index.keys where !names.contains(key) && inFlight[key] == nil {
            index[key] = nil
        }
        let history = now.addingTimeInterval(-Double(SongCacheEviction.playHistoryDays) * 86_400)
        for key in index.keys { index[key]?.plays.removeAll { $0 < history } }

        let entries = present.compactMap { file -> SongCacheEntry? in
            let key = file.url.lastPathComponent
            guard let entry = index[key] else { return nil }
            return SongCacheEntry(key: key, size: file.size, added: entry.added, plays: entry.plays)
        }
        var protected = Set(inFlight.keys)
        [currentKey, prefetchedKey].compactMap { $0 }.forEach { protected.insert($0) }
        for key in SongCacheEviction.keysToRemove(entries: entries, protected: protected,
                                                  now: now, policy: SongCacheSettings.current) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(key))
            index[key] = nil
        }
        self.index = index
        scheduleSave()
    }

    private func loadedIndex() -> [String: IndexEntry] {
        if let index { return index }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let loaded = (try? Data(contentsOf: indexURL)).flatMap { try? decoder.decode([String: IndexEntry].self, from: $0) } ?? [:]
        index = loaded
        return loaded
    }

    /// Writes the index a few seconds after the last change, so a burst is one write.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        queue.asyncAfter(deadline: .now() + 3) {
            self.saveScheduled = false
            guard let index = self.index else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            if let data = try? encoder.encode(index) {
                try? data.write(to: self.indexURL, options: .atomic)
            }
        }
    }

    /// Song files only: not the index, not the `typed/` folder.
    private func files() -> [(url: URL, size: Int64, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard url != indexURL, url.lastPathComponent != "index.json" else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { return nil }
            return (url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
        }
    }
}
