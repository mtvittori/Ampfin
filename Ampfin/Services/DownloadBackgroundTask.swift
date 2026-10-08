// DownloadBackgroundTask.swift
// Keeps downloads going when Ampfin leaves the screen. It is an iOS 26 continued
// processing task: the system shows it as a live activity with the progress and a stop
// button, and keeps the app running while it reports progress. Without it the
// downloads froze as soon as the app went to the background.

#if os(iOS)
import BackgroundTasks
import Foundation

final class DownloadBackgroundTask {
    static let shared = DownloadBackgroundTask()

    /// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist ("<bundle id>.downloads.*").
    private let prefix = (Bundle.main.bundleIdentifier ?? "com.mtvittori.Ampfin") + ".downloads"
    private var task: BGContinuedProcessingTask?
    /// The songs of the current run of downloads; empty when none is running.
    private var batch: [String] = []
    private var lastProgressUpdate = Date.distantPast

    /// Starts the live activity for songs just queued (main thread); called by
    /// DownloadManager for every download. Songs queued while one runs join it.
    func begin(itemIds: [String]) {
        guard !itemIds.isEmpty else { return }
        let alreadyRunning = !batch.isEmpty
        batch += itemIds.filter { !batch.contains($0) }
        if alreadyRunning {
            refresh()
            return
        }
        // One handler per identifier, registered just before the request: a single
        // handler for the wildcard isn't matched to the submitted ids, and submitting
        // without a match raises an exception that aborted the app.
        let identifier = "\(prefix).\(UUID().uuidString.prefix(8))"
        guard register(identifier) else {
            print("[Download] Background task not registered: \(identifier)")
            return
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Download Ampfin",
            subtitle: subtitle(done: 0)
        )
        // Not queued for later: if the system can't run it now, the downloads simply go on
        // while the app is open, as before.
        request.strategy = .fail
        var submitError: Error?
        let exception = AmpfinCatchException {
            do { try BGTaskScheduler.shared.submit(request) } catch { submitError = error }
        }
        if let exception {
            print("[Download] Background task refused: \(exception.reason ?? "")")
        } else if let submitError {
            print("[Download] Background task not accepted: \(submitError)")
        }
    }

    private func register(_ identifier: String) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            guard let self, let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // The batch may already be over by the time the system starts the task, or
            // an earlier request already carries it.
            guard !self.batch.isEmpty, self.task == nil else {
                task.setTaskCompleted(success: true)
                return
            }
            self.task = task
            task.expirationHandler = { [weak self] in
                // Stopped from the live activity, or the system needed the resources.
                DispatchQueue.main.async { self?.stop() }
            }
            self.refresh()
        }
    }

    /// A download moved forward (main thread). Throttled: progress arrives many times a second.
    func progressChanged() {
        guard task != nil, Date().timeIntervalSince(lastProgressUpdate) > 0.5 else { return }
        refresh()
    }

    /// A download finished, failed or was removed (main thread).
    func refresh() {
        guard !batch.isEmpty else { return }
        lastProgressUpdate = Date()
        let manager = DownloadManager.shared
        var done = 0
        var partial = 0.0
        var running = false
        for id in batch {
            switch manager.downloadStates[id] ?? .notDownloaded {
            case .downloaded: done += 1
            case .downloading(let progress): running = true; partial += progress
            case .notDownloaded: break
            }
        }
        if let task {
            // Hundredths of a song, so a long FLAC still shows movement and the task
            // doesn't look stalled to the system.
            task.progress.totalUnitCount = Int64(batch.count * 100)
            task.progress.completedUnitCount = Int64(done * 100) + Int64(partial * 100)
            task.updateTitle(task.title, subtitle: subtitle(done: done))
        }
        if !running {
            finish(success: done == batch.count)
        }
    }

    /// Stops what hasn't finished; the songs already saved stay.
    private func stop() {
        let ids = batch
        batch = []
        for id in ids {
            if case .downloading = DownloadManager.shared.downloadStates[id] ?? .notDownloaded {
                DownloadManager.shared.removeDownload(for: id)
            }
        }
        finish(success: false)
    }

    private func finish(success: Bool) {
        task?.setTaskCompleted(success: success)
        task = nil
        batch = []
    }

    private func subtitle(done: Int) -> String {
        "\(done) di \(batch.count) brani"
    }
}
#endif
