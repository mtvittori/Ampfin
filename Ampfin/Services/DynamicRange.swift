import Foundation
import SwiftUI

// Dynamic range (DR) in the "TT DR" / foobar2000 foo_dr_meter sense, measured on the
// decoded file: per channel, 3 s blocks, DR = second-highest block peak over the RMS of
// the loudest 20% of blocks, in dB, averaged over the channels.
//
// Shared by the engine and the UI: names and signatures here must not change. The
// measurement is in DRMeter.swift, the sync format in DRSync.swift.

/// One measured song.
struct DRResult: Codable, Equatable {
    /// Unrounded DR in dB (foobar shows it rounded: `dr`).
    let value: Double
    /// When it was measured.
    let measured: Date

    /// The integer foobar prints, "DR12".
    var dr: Int { Int(value.rounded()) }
}

enum DRSettings {
    /// Settings → show the DR label next to the audio format in the player. Off by default.
    static let playerBadgeKey = "drPlayerBadge"
}

/// Every DR measured so far, keyed by Jellyfin item id. Saved on disk and shared between
/// devices through Jellyfin.
@MainActor
final class DRStore: ObservableObject {
    static let shared = DRStore()

    @Published private(set) var results: [String: DRResult] = [:]

    private var api: JellyfinAPIService?
    /// Results (local or merged) the server doesn't have yet.
    private var needsUpload = false
    private var isSyncing = false
    private var resyncRequested = false
    private var saveTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?

    init() {
        results = Self.loadFromDisk()
    }

    func result(for itemId: String) -> DRResult? { results[itemId] }

    /// The album DR as foobar prints it: the rounded mean of its measured songs, nil if none is measured.
    func albumDR(trackIds: [String]) -> Int? {
        let values = trackIds.compactMap { results[$0]?.value }
        guard !values.isEmpty else { return nil }
        return Int((values.reduce(0, +) / Double(values.count)).rounded())
    }

    /// Stores a measurement; it reaches the disk and the server a little later.
    func record(_ itemId: String, _ result: DRResult) {
        results[itemId] = result
        needsUpload = true
        scheduleSave()
        scheduleUpload(after: .seconds(10))
    }

    /// Sends what is pending now (end of a run) instead of waiting for the debounce.
    func flushUpload() {
        guard needsUpload else { return }
        scheduleUpload(after: .zero)
    }

    // MARK: - Disk

    private static let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Ampfin", isDirectory: true).appendingPathComponent("dr-results.json")
    }()

    private static func loadFromDisk() -> [String: DRResult] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: DRResult].self, from: data)) ?? [:]
    }

    /// Waits for a burst of results to end, then writes the file off the main thread.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let snapshot = results
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                let url = Self.fileURL
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }.value
        }
    }

    // MARK: - Sync through Jellyfin

    /// Called once logged in: merges the results on the server into the local ones and
    /// uploads whatever the server lacks.
    func connect(api: JellyfinAPIService) async {
        self.api = api
        DRAnalyzer.shared.attach(api: api)
        await sync()
    }

    private func scheduleUpload(after delay: Duration) {
        guard api != nil else { return }
        uploadTask?.cancel()
        uploadTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    /// One at a time; a request that arrives meanwhile runs again afterwards.
    private func sync() async {
        guard api != nil else { return }
        if isSyncing {
            resyncRequested = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            resyncRequested = false
            await syncOnce()
        } while resyncRequested
    }

    private func syncOnce() async {
        guard let api else { return }
        do {
            let remote = try await api.loadDRChunks()
            let remoteTenths = remote.map { DRSyncCoding.decode(chunks: $0.chunks) } ?? [:]
            merge(remoteTenths, date: remote?.date ?? .distantPast)

            // Upload when the union holds something the server has different or lacks.
            let differs = results.contains { remoteTenths[$0.key] != DRSyncCoding.tenths($0.value.value) }
            guard differs || needsUpload else { return }
            needsUpload = false
            let chunks = DRSyncCoding.encode(results)
            do {
                try await api.saveDRChunks(chunks, date: Date())
            } catch {
                needsUpload = true
                throw error
            }
        } catch {
            // Offline or server error: keep the flag and try again in a minute.
            if needsUpload { scheduleUpload(after: .seconds(60)) }
        }
    }

    /// Union of the two sides; per song the newer measurement wins. The server's values
    /// carry the date of its last upload as their measurement date.
    private func merge(_ remote: [String: Int], date: Date) {
        var merged = results
        for (id, tenths) in remote {
            if let local = merged[id] {
                guard DRSyncCoding.tenths(local.value) != tenths, date > local.measured else { continue }
            }
            merged[id] = DRResult(value: Double(tenths) / 10, measured: date)
        }
        guard merged != results else { return }
        results = merged
        scheduleSave()
    }
}

/// Runs the measurements: the whole library on the Mac, only the songs on disk on iOS.
@MainActor
final class DRAnalyzer: ObservableObject {
    static let shared = DRAnalyzer()

    @Published private(set) var isRunning = false
    /// Songs measured in the current run, and how many it will measure.
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    /// Title of the song being measured.
    @Published private(set) var currentTitle: String?
    /// Last error to show under the button, nil when fine.
    @Published private(set) var lastError: String?

    /// True on macOS: it downloads and measures every song. False on iOS: only downloaded or cached songs.
    var analyzesWholeLibrary: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private var api: JellyfinAPIService?
    private var runTask: Task<Void, Never>?
    /// Songs being measured right now, by the run or by the automatic queue: never twice.
    private var measuring: Set<String> = []
    private var autoQueue: [String] = []
    private var autoTask: Task<Void, Never>?

    func attach(api: JellyfinAPIService) {
        self.api = api
    }

    /// How many of `items` could be measured now and still have no DR (for the button label).
    func pendingCount(in items: [AudioItem]) -> Int {
        let results = DRStore.shared.results
        if analyzesWholeLibrary {
            return items.reduce(0) { results[$1.Id] == nil ? $0 + 1 : $0 }
        }
        return items.reduce(0) { count, item in
            results[item.Id] == nil && hasLocalFile(item.Id) ? count + 1 : count
        }
    }

    /// Measures every song in `items` that has no DR yet (on iOS only those with a local file).
    func start(items: [AudioItem]) {
        guard !isRunning else { return }
        let results = DRStore.shared.results
        var seen = Set<String>()
        let queue = items.filter { item in
            results[item.Id] == nil && seen.insert(item.Id).inserted
                && (analyzesWholeLibrary || hasLocalFile(item.Id))
        }
        guard !queue.isEmpty else { return }
        isRunning = true
        done = 0
        total = queue.count
        currentTitle = nil
        lastError = nil
        runTask = Task { await run(queue) }
    }

    func stop() {
        runTask?.cancel()
        currentTitle = nil
    }

    // MARK: - Run

    private func run(_ queue: [AudioItem]) async {
        // The Mac is busy downloading too; the phone only reads files, one at a time.
        let limit = analyzesWholeLibrary ? 2 : 1
        var next = 0
        var inFlight = 0
        var failures = 0
        await withTaskGroup(of: Outcome.self) { group in
            while true {
                while inFlight < limit, next < queue.count, !Task.isCancelled {
                    let item = queue[next]
                    next += 1
                    guard measuring.insert(item.Id).inserted else {
                        done += 1  // the automatic queue has it
                        continue
                    }
                    currentTitle = item.Name
                    let job = makeJob(for: item)
                    group.addTask { await Self.measure(job) }
                    inFlight += 1
                }
                guard inFlight > 0, let outcome = await group.next() else { break }
                inFlight -= 1
                measuring.remove(outcome.id)
                switch outcome.result {
                case .success(let value):
                    DRStore.shared.record(outcome.id, DRResult(value: value, measured: Date()))
                    done += 1
                case .failure(let error):
                    if error is CancellationError { break }
                    failures += 1
                    done += 1
                    let reason = error.localizedDescription
                    lastError = failures == 1 ? "\(outcome.title): \(reason)" : "\(failures) brani non misurati, ultimo \(outcome.title): \(reason)"
                }
            }
        }
        isRunning = false
        currentTitle = nil
        runTask = nil
        DRStore.shared.flushUpload()
    }

    private struct Job: Sendable {
        let id: String
        let title: String
        let fileExtension: String
        /// A copy already on this device, measured as it is.
        let localFile: URL?
        /// Otherwise the original is downloaded with this.
        let request: URLRequest?
    }

    private struct Outcome: Sendable {
        let id: String
        let title: String
        let result: Result<Double, Error>
    }

    private func makeJob(for item: AudioItem) -> Job {
        let local = localFile(for: item.Id)
        return Job(id: item.Id, title: item.Name, fileExtension: item.containerName ?? "audio",
                   localFile: local, request: local == nil ? api?.originalFileRequest(for: item.Id) : nil)
    }

    private nonisolated static func measure(_ job: Job) async -> Outcome {
        do {
            let value = try await measureValue(job)
            return Outcome(id: job.id, title: job.title, result: .success(value))
        } catch {
            return Outcome(id: job.id, title: job.title, result: .failure(error))
        }
    }

    private nonisolated static func measureValue(_ job: Job) async throws -> Double {
        if let file = job.localFile { return try await DRMeter.measureAsync(fileURL: file) }
        guard let request = job.request else { throw APIError.invalidURL }

        let (downloaded, response) = try await JellyfinAPIService.urlSession.download(for: request)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        // The decoder looks at the extension, which the temporary download doesn't have.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ampfin-dr", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(UUID().uuidString).\(job.fileExtension)")
        try FileManager.default.moveItem(at: downloaded, to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try await DRMeter.measureAsync(fileURL: file)
    }

    // MARK: - Local files

    /// The song's original on this device: a download, or the one the player cached.
    private func localFile(for itemId: String) -> URL? {
        if let url = DownloadManager.shared.localURL(for: itemId) { return url }
        guard let key = cacheKey(for: itemId) else { return nil }
        return AudioStreamCache.shared.cachedFile(forKey: key)
    }

    /// Cheap version for counting thousands of songs: no file attributes touched.
    private func hasLocalFile(_ itemId: String) -> Bool {
        if DownloadManager.shared.status(of: itemId) == .downloaded { return true }
        guard let key = cacheKey(for: itemId) else { return false }
        return AudioStreamCache.shared.containsFile(forKey: key)
    }

    /// The player caches the original under the key of this URL (other variants are transcodes).
    private func cacheKey(for itemId: String) -> String? {
        guard let url = api?.streamURL(for: itemId) else { return nil }
        return AudioStreamCache.shared.key(itemId: itemId, url: url)
    }

    // MARK: - After a download

    /// Called when a song finishes downloading: measured in the background if it has no DR,
    /// one at a time and without touching the state of a manual run.
    func songDownloaded(itemId: String) {
        guard DRStore.shared.results[itemId] == nil, !autoQueue.contains(itemId),
              !measuring.contains(itemId) else { return }
        autoQueue.append(itemId)
        guard autoTask == nil else { return }
        autoTask = Task(priority: .background) { await drainAutoQueue() }
    }

    private func drainAutoQueue() async {
        while !autoQueue.isEmpty {
            let itemId = autoQueue.removeFirst()
            guard DRStore.shared.results[itemId] == nil, !measuring.contains(itemId),
                  let file = DownloadManager.shared.localURL(for: itemId) else { continue }
            measuring.insert(itemId)
            let value = try? await DRMeter.measureAsync(fileURL: file, qos: .background)
            measuring.remove(itemId)
            if let value {
                DRStore.shared.record(itemId, DRResult(value: value, measured: Date()))
            }
        }
        autoTask = nil
    }
}
