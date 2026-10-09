import Foundation
import Observation

enum DownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
}

/// What a single song row observes. Status and progress are separate properties, so a row
/// that only shows the "downloaded" mark is never redrawn by the progress ticks: only the
/// small ring of that song reads `progress`.
@Observable
final class DownloadItemState {
    enum Status { case notDownloaded, downloading, downloaded }

    fileprivate(set) var status: Status
    fileprivate(set) var progress: Double = 0

    fileprivate init(status: Status) { self.status = status }
}

/// Changes whenever any song starts, finishes or is removed (never on progress). Read by the
/// few views that look at many songs together (the "download all" button, Settings, album menu).
@Observable
final class DownloadActivity {
    fileprivate(set) var revision = 0
}

/// Downloaded songs, the queue and the live progress. Main thread only, except the URLSession
/// callbacks, which hand over to it. Views never observe the manager itself: they read
/// `itemState(for:)` (one song) or `activity` (aggregate), so a download tick doesn't
/// invalidate lists of thousands of songs.
final class DownloadManager: NSObject {
    static let shared = DownloadManager()

    let activity = DownloadActivity()

    private var items: [String: DownloadItemState] = [:]
    /// Queued or running, mirrored by the items' status.
    private var downloadingIds: Set<String> = []
    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    private var progressObservations: [String: NSKeyValueObservation] = [:]
    private let fileManager = FileManager.default

    // Progress arrives on the session's queue for every received chunk: it is parked here
    // and published at most every `progressInterval`, in one main-thread pass.
    private let progressLock = NSLock()
    private var latestProgress: [String: Double] = [:]
    private var flushScheduled = false
    private let progressInterval = 0.25

    // Persistent metadata: set of downloaded item IDs (written with a delay, see scheduleSave)
    private let downloadedIdsKey = "downloaded_item_ids"
    private var downloadedIds: Set<String> {
        didSet { scheduleSave() }
    }
    private var saveWork: DispatchWorkItem?

    private let fileIndex: FileIndex

    private static var downloadsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("AudioDownloads")
    }

    private override init() {
        if let saved = UserDefaults.standard.array(forKey: downloadedIdsKey) as? [String] {
            self.downloadedIds = Set(saved)
        } else {
            self.downloadedIds = []
        }
        let directory = Self.downloadsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileIndex = FileIndex(directory: directory)
        super.init()
        // Scan the folder once, off the main thread, so playback never waits for it.
        let index = fileIndex
        DispatchQueue.global(qos: .utility).async { index.warmUp() }
    }

    // MARK: - Query

    /// Whether the song is downloaded. In a view body this registers the aggregate `activity`
    /// (use `isDownloadedLive` in a row instead).
    func isDownloaded(_ itemId: String) -> Bool {
        _ = activity.revision
        return downloadedIds.contains(itemId)
    }

    /// For a single row's body: only that song's status is observed.
    func isDownloadedLive(_ itemId: String) -> Bool {
        itemState(for: itemId).status == .downloaded
    }

    /// The observable state of one song, created on first use.
    func itemState(for itemId: String) -> DownloadItemState {
        if let state = items[itemId] { return state }
        let state = DownloadItemState(status: status(of: itemId))
        items[itemId] = state
        return state
    }

    /// Plain status without observation: a view reading many songs together (with `activity`)
    /// must not register every song's own state.
    func status(of itemId: String) -> DownloadItemState.Status {
        if downloadedIds.contains(itemId) { return .downloaded }
        return downloadingIds.contains(itemId) ? .downloading : .notDownloaded
    }

    /// Status plus progress, for code that is not a view.
    func state(of itemId: String) -> DownloadState {
        switch status(of: itemId) {
        case .notDownloaded: return .notDownloaded
        case .downloading: return .downloading(progress: items[itemId]?.progress ?? 0)
        case .downloaded: return .downloaded
        }
    }

    /// Whether any song has been downloaded. Observed like `isDownloaded`.
    var hasDownloads: Bool {
        _ = activity.revision
        return !downloadedIds.isEmpty
    }

    /// Returns the local file URL if the track is downloaded and the file exists.
    /// Self-heals if metadata is stale (file deleted externally).
    func localURL(for itemId: String) -> URL? {
        guard downloadedIds.contains(itemId) else { return nil }

        if let url = fileIndex.url(for: itemId), fileManager.fileExists(atPath: url.path) {
            return url
        }

        // File missing: clean up stale metadata
        fileIndex.remove(itemId)
        downloadedIds.remove(itemId)
        setStatus(.notDownloaded, for: itemId)
        return nil
    }

    /// Publishes a status change. Progress only changes through `flushProgress`.
    private func setStatus(_ status: DownloadItemState.Status, for itemId: String) {
        if status == .downloading { downloadingIds.insert(itemId) } else { downloadingIds.remove(itemId) }
        let state = itemState(for: itemId)
        guard state.status != status else { return }
        state.status = status
        state.progress = 0
        activity.revision &+= 1
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let ids = Array(self.downloadedIds)
            let key = self.downloadedIdsKey
            DispatchQueue.global(qos: .utility).async { UserDefaults.standard.set(ids, forKey: key) }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: - Download

    /// Songs waiting their turn: "Scarica tutti" on the favorites queues hundreds at once.
    private var pending: [(item: AudioItem, streamURL: URL)] = []
    private let maxConcurrentDownloads = 3

    func download(item: AudioItem, streamURL: URL) {
        guard !downloadedIds.contains(item.Id), activeTasks[item.Id] == nil,
              !pending.contains(where: { $0.item.Id == item.Id }) else { return }

        setStatus(.downloading, for: item.Id)
        pending.append((item, streamURL))
        startPendingDownloads()
        #if os(iOS)
        // Every download goes on in the background (a song, an album, all the favorites):
        // songs added while one runs join its live activity.
        DownloadBackgroundTask.shared.begin(itemIds: [item.Id])
        #endif
    }

    /// Whether any song is downloading or waiting.
    var hasActiveDownloads: Bool { !activeTasks.isEmpty || !pending.isEmpty }

    private func startPendingDownloads() {
        while activeTasks.count < maxConcurrentDownloads, !pending.isEmpty {
            let next = pending.removeFirst()
            start(item: next.item, streamURL: next.streamURL)
        }
    }

    private func start(item: AudioItem, streamURL: URL) {
        let container = item.containerName
        let task = JellyfinAPIService.urlSession.downloadTask(with: streamURL) { [weak self] tempURL, _, error in
            // Move file IMMEDIATELY (still on the session's queue): the temp file is deleted
            // after this closure returns.
            guard let self else { return }
            let file = self.moveDownloadedFile(itemId: item.Id, container: container, tempURL: tempURL, error: error)
            if let file { self.fileIndex.set(item.Id, file) }
            DispatchQueue.main.async {
                self.activeTasks.removeValue(forKey: item.Id)
                self.progressObservations.removeValue(forKey: item.Id)
                if file != nil {
                    self.downloadedIds.insert(item.Id)
                    self.setStatus(.downloaded, for: item.Id)
                } else {
                    self.setStatus(.notDownloaded, for: item.Id)
                }
                self.startPendingDownloads()
                #if os(iOS)
                DownloadBackgroundTask.shared.refresh()
                #endif
            }
        }

        // KVO fires for every received chunk, on the session's queue: only park the value.
        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            self?.report(progress: progress.fractionCompleted, for: item.Id)
        }
        progressObservations[item.Id] = observation
        activeTasks[item.Id] = task
        task.resume()
    }

    /// Any thread. Keeps the latest value per song and schedules a single main-thread flush.
    private func report(progress: Double, for itemId: String) {
        progressLock.lock()
        latestProgress[itemId] = progress
        let needsFlush = !flushScheduled
        flushScheduled = true
        progressLock.unlock()
        if needsFlush {
            DispatchQueue.main.asyncAfter(deadline: .now() + progressInterval) { [weak self] in
                self?.flushProgress()
            }
        }
    }

    private func flushProgress() {
        progressLock.lock()
        let batch = latestProgress
        latestProgress = [:]
        flushScheduled = false
        progressLock.unlock()

        var changed = false
        for (itemId, value) in batch {
            // A late update after a stop would leave the song "downloading" forever.
            guard activeTasks[itemId] != nil else { continue }
            let state = itemState(for: itemId)
            // Under a percent the ring wouldn't visibly move.
            guard value - state.progress >= 0.01 || (value >= 1 && state.progress < 1) else { continue }
            state.progress = value
            changed = true
        }
        #if os(iOS)
        if changed { DownloadBackgroundTask.shared.progressChanged() }
        #endif
    }

    /// Moves the temp file to the downloads directory synchronously and returns where it went.
    /// Must be called on the URLSession callback thread (before the temp file is deleted).
    private func moveDownloadedFile(itemId: String, container: String?, tempURL: URL?, error: Error?) -> URL? {
        guard let tempURL, error == nil else {
            print("[Download] Errore: \(error?.localizedDescription ?? "sconosciuto")")
            return nil
        }

        let ext = container?.lowercased() ?? "audio"
        let dir = Self.downloadsDirectory

        // Ensure directory exists
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let destination = dir.appendingPathComponent("\(itemId).\(ext)")

        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: tempURL, to: destination)
            print("[Download] Completato: \(destination.lastPathComponent)")
            return destination
        } catch {
            print("[Download] Errore spostamento file: \(error)")
            return nil
        }
    }

    // MARK: - Remove

    func removeDownload(for itemId: String) {
        // Cancel if in progress or waiting
        pending.removeAll { $0.item.Id == itemId }
        activeTasks[itemId]?.cancel()
        activeTasks.removeValue(forKey: itemId)
        progressObservations.removeValue(forKey: itemId)

        // Remove file from disk
        if let url = fileIndex.url(for: itemId) {
            try? fileManager.removeItem(at: url)
            fileIndex.remove(itemId)
        }
        downloadedIds.remove(itemId)
        setStatus(.notDownloaded, for: itemId)
        #if os(iOS)
        DownloadBackgroundTask.shared.refresh()
        #endif
    }

    func removeAllDownloads() {
        let ids = downloadedIds
        for id in ids {
            removeDownload(for: id)
        }
    }

    // MARK: - Storage

    func totalDownloadSize() -> Int64 {
        guard let files = try? fileManager.contentsOfDirectory(
            at: Self.downloadsDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        return files.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }
}

/// Song id -> file in the downloads folder, scanned once and then kept up to date, so
/// resolving a song at playback doesn't list the whole folder. Thread-safe.
private final class FileIndex {
    private let directory: URL
    private let lock = NSLock()
    private var urls: [String: URL]?

    init(directory: URL) { self.directory = directory }

    func warmUp() {
        lock.lock(); defer { lock.unlock() }
        load()
    }

    func url(for itemId: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        load()
        return urls?[itemId]
    }

    func set(_ itemId: String, _ url: URL) {
        lock.lock(); defer { lock.unlock() }
        load()
        urls?[itemId] = url
    }

    func remove(_ itemId: String) {
        lock.lock(); defer { lock.unlock() }
        load()
        urls?[itemId] = nil
    }

    /// Files are named "<id>.<container>". Call with the lock held.
    private func load() {
        guard urls == nil else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var map: [String: URL] = [:]
        for file in files { map[file.deletingPathExtension().lastPathComponent] = file }
        urls = map
    }
}
