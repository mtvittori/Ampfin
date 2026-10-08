import Foundation
import Combine

enum DownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
}

final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    /// Key: AudioItem.Id, Value: current download state
    @Published private(set) var downloadStates: [String: DownloadState] = [:]

    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    private var progressObservations: [String: NSKeyValueObservation] = [:]
    private let fileManager = FileManager.default

    // Persistent metadata: set of downloaded item IDs
    private let downloadedIdsKey = "downloaded_item_ids"
    private var downloadedIds: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(downloadedIds), forKey: downloadedIdsKey)
        }
    }

    private var downloadsDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("AudioDownloads")
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private override init() {
        if let saved = UserDefaults.standard.array(forKey: downloadedIdsKey) as? [String] {
            self.downloadedIds = Set(saved)
        } else {
            self.downloadedIds = []
        }
        super.init()

        // Rebuild published states from persisted IDs
        for id in downloadedIds {
            downloadStates[id] = .downloaded
        }
    }

    // MARK: - Query

    func isDownloaded(_ itemId: String) -> Bool {
        downloadedIds.contains(itemId)
    }

    /// Returns the local file URL if the track is downloaded and the file exists.
    /// Self-heals if metadata is stale (file deleted externally).
    func localURL(for itemId: String) -> URL? {
        guard downloadedIds.contains(itemId) else { return nil }

        let dir = downloadsDirectory
        if let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
           let match = files.first(where: { $0.lastPathComponent.hasPrefix(itemId) }) {
            return match
        }

        // File missing — clean up stale metadata
        downloadedIds.remove(itemId)
        downloadStates[itemId] = .notDownloaded
        return nil
    }

    // MARK: - Download

    /// Songs waiting their turn: "Scarica tutti" on the favorites queues hundreds at once.
    private var pending: [(item: AudioItem, streamURL: URL)] = []
    private let maxConcurrentDownloads = 3

    func download(item: AudioItem, streamURL: URL) {
        guard !isDownloaded(item.Id), activeTasks[item.Id] == nil,
              !pending.contains(where: { $0.item.Id == item.Id }) else { return }

        downloadStates[item.Id] = .downloading(progress: 0)
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
        let container = item.MediaSources?.first?.Container
        let task = JellyfinAPIService.urlSession.downloadTask(with: streamURL) { [weak self] tempURL, _, error in
            // Move file IMMEDIATELY — temp file is deleted after this closure returns
            guard let self else { return }
            let result = self.moveDownloadedFile(itemId: item.Id, container: container, tempURL: tempURL, error: error)
            DispatchQueue.main.async {
                self.activeTasks.removeValue(forKey: item.Id)
                self.progressObservations.removeValue(forKey: item.Id)
                if result {
                    self.downloadedIds.insert(item.Id)
                    self.downloadStates[item.Id] = .downloaded
                } else {
                    self.downloadStates[item.Id] = .notDownloaded
                }
                self.startPendingDownloads()
                #if os(iOS)
                DownloadBackgroundTask.shared.refresh()
                #endif
            }
        }

        // KVO for progress tracking
        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                // A late update after a stop would leave the song "downloading" forever.
                guard let self, self.activeTasks[item.Id] != nil else { return }
                self.downloadStates[item.Id] = .downloading(progress: progress.fractionCompleted)
                #if os(iOS)
                DownloadBackgroundTask.shared.progressChanged()
                #endif
            }
        }
        progressObservations[item.Id] = observation
        activeTasks[item.Id] = task
        task.resume()
    }

    /// Moves the temp file to the downloads directory synchronously.
    /// Must be called on the URLSession callback thread (before the temp file is deleted).
    private func moveDownloadedFile(itemId: String, container: String?, tempURL: URL?, error: Error?) -> Bool {
        guard let tempURL, error == nil else {
            print("[Download] Errore: \(error?.localizedDescription ?? "sconosciuto")")
            return false
        }

        let ext = container?.lowercased() ?? "audio"
        let dir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AudioDownloads")

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
            return true
        } catch {
            print("[Download] Errore spostamento file: \(error)")
            return false
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
        if let url = localURL(for: itemId) {
            try? fileManager.removeItem(at: url)
        }
        downloadedIds.remove(itemId)
        downloadStates[itemId] = .notDownloaded
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
            at: downloadsDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        return files.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }
}
