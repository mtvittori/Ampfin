import Foundation
import AVFoundation
import Combine
import MediaPlayer

final class AudioPlayerManager: ObservableObject {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentlyPlayingItem: AudioItem?
    @Published private(set) var currentTime: TimeInterval = 0

    // MARK: - Audio Output Info (source metadata)
    @Published private(set) var currentBitrate: Double = 0          // kbps
    @Published private(set) var currentSampleRate: Double = 0       // Hz
    @Published private(set) var currentOutputDevice: String = ""
    @Published private(set) var currentCodec: String = ""
    @Published private(set) var isDirectStream: Bool = true

    // MARK: - Device Output Info (real hardware values)
    @Published private(set) var deviceSampleRate: Double = 0        // Hz (actual hardware)
    @Published private(set) var deviceOutputChannels: Int = 0
    @Published private(set) var deviceOutputLatency: TimeInterval = 0

    public var repeatMode: RepeatMode = .off

    // MARK: - AVAudioEngine playback (via EqualizerManager)

    private var eqManager: EqualizerManager { EqualizerManager.shared }
    private var audioEngine: AVAudioEngine { eqManager.audioEngine }
    private var playerNode: AVAudioPlayerNode { eqManager.playerNode }

    private var currentAudioFile: AVAudioFile?
    /// The typed link of the song opened before the current one (see typedLink).
    private var previousTypedLink: URL?
    private var timeUpdateTimer: Timer?
    private var scheduledStartFrame: AVAudioFramePosition = 0
    private var seekOffset: TimeInterval = 0
    /// Incremented each time we schedule new audio; stale completion handlers are ignored.
    private var playbackGeneration: Int = 0
    /// What the user wants, set at once by play and pause, also while the song is still
    /// downloading. A download that ends after a pause only loads the song.
    private var wantsToPlay = false
    /// Bumped by every play request and by stop: a download that finishes with an older
    /// number is dropped, so it can't start a song the user has moved on from.
    private var loadGeneration = 0
    /// A download for the current song is in progress.
    @Published private(set) var isLoading = false
    /// The current file is queued on the player node from its start (see queueFromStart).
    private var isQueued = false

    /// Published so the "A seguire" list follows additions and removals.
    @Published private var playQueue: [AudioItem] = []

    /// Shuffle of what's coming up; `originalQueue` brings the order back when it goes off.
    @Published private(set) var isShuffled = false
    private var originalQueue: [AudioItem]?

    /// Autoplay: when the queue is about to end, similar songs are added (Jellyfin's
    /// Instant Mix), like Spotify's autoplay. Saved across launches.
    @Published var autoplayEnabled: Bool = UserDefaults.standard.object(forKey: "autoplayEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoplayEnabled, forKey: "autoplayEnabled")
            if autoplayEnabled { topUpAutoplay() } else { removeAutoplayItems() }
        }
    }
    /// Songs added by autoplay, shown under their own heading in the queue.
    @Published private(set) var autoplayIds: Set<String> = []
    /// Similar songs for a song; injected by the view model (Jellyfin Instant Mix).
    var similarProvider: ((AudioItem) async -> [AudioItem])?
    private var autoplayTask: Task<Void, Never>?

    /// App volume, 0...1, applied to the engine's output (the Mac player has its own slider).
    @Published var volume: Float = UserDefaults.standard.object(forKey: "playerVolume") as? Float ?? 1 {
        didSet {
            UserDefaults.standard.set(volume, forKey: "playerVolume")
            eqManager.audioEngine.mainMixerNode.outputVolume = volume
        }
    }

    /// The whole play queue, for the "Up next" list.
    var queue: [AudioItem] { playQueue }

    /// The songs after the one playing.
    var upNext: [AudioItem] {
        guard let current = currentlyPlayingItem,
              let index = playQueue.firstIndex(where: { $0.id == current.id }) else { return [] }
        return Array(playQueue.dropFirst(index + 1))
    }

    private var streamURLProvider: ((String) -> URL?)?
    var artworkURLProvider: ((String, Int) -> URL?)?

    /// Reports to the Jellyfin server that an item was played (updates its LastPlayedDate,
    /// which powers "recently played" queries). Injected so this class stays decoupled from JellyfinAPIService.
    var markPlayedProvider: ((String) async throws -> Void)?
    /// Called after a play report succeeds, so the view model can refresh "recently played" lists.
    var onDidReportPlayed: ((AudioItem) -> Void)?
    private var playedReportTask: Task<Void, Never>?

    private var cachedNowPlayingArtworkImage: PlatformImage?

    // Temp file management
    private var currentTempFile: URL?
    private var downloadTask: URLSessionDataTask?

    /// A call (or Siri, an alarm) took the audio: nothing may restart it until it ends.
    private var isInterrupted = false
    /// The song was playing when the interruption began, so it resumes when it ends.
    private var resumeAfterInterruption = false

    #if os(iOS)
    private var routeChangeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    #endif

    init(streamURLProvider: @escaping (String) -> URL?, artworkURLProvider: ((String, Int) -> URL?)? = nil) {
        self.streamURLProvider = streamURLProvider
        self.artworkURLProvider = artworkURLProvider
        eqManager.audioEngine.mainMixerNode.outputVolume = volume
        configureAudioSessionIfNeeded()
        setupRemoteCommandCenter()
        // A new output (CarPlay, Bluetooth) stops the engine: start it again if a song was on.
        // Not during a call: answering in CarPlay changes the output too, and the music
        // started again over the call.
        eqManager.onConfigurationChange = { [weak self] in
            // Not while a song is still loading: there is nothing queued to restart.
            guard let self, self.isPlaying, self.isQueued, !self.isInterrupted else { return }
            if !self.startPlayerNode() {
                self.markPausedAfterFailedStart()
            }
        }
        #if os(iOS)
        setupRouteChangeObserver()
        setupInterruptionObserver()
        #endif
    }

    // MARK: - Playback

    func play(item: AudioItem, in queue: [AudioItem]) {
        guard let url = streamURLProvider?(item.Id) else {
            print("Errore: URL per lo streaming non valido.")
            return
        }

        // A new list from outside starts a new context: no shuffle, no autoplay songs.
        // Moving within the queue (next, previous, repeat) passes the queue itself.
        if queue.map(\.id) != playQueue.map(\.id) {
            isShuffled = false
            originalQueue = nil
            autoplayIds = []
        }
        self.playQueue = queue
        stop()

        cachedNowPlayingArtworkImage = nil
        currentlyPlayingItem = item
        wantsToPlay = true
        isPlaying = true
        updateNowPlayingInfo()
        scheduleReportPlayed(for: item)

        // Download audio to temp file, then play via AVAudioEngine
        downloadAndPlay(url: url, item: item, generation: loadGeneration)
    }

    /// Reports the item as played once it's had a few seconds of genuine playback,
    /// so skipping through tracks quickly doesn't pollute "recently played".
    private func scheduleReportPlayed(for item: AudioItem) {
        playedReportTask?.cancel()
        playedReportTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            // Paused during the download: it wasn't played, so it isn't reported.
            guard let self, !Task.isCancelled, self.isPlaying, self.currentlyPlayingItem?.Id == item.Id else { return }
            do {
                try await self.markPlayedProvider?(item.Id)
                await MainActor.run { self.onDidReportPlayed?(item) }
            } catch {
                // Non-critical — "recently played" simply won't reflect this listen.
            }
        }
    }

    private func downloadAndPlay(url: URL, item: AudioItem, generation: Int) {
        // Cancel any ongoing download
        downloadTask?.cancel()

        // If it's a local file, play directly
        if url.isFileURL {
            fileLoaded(url)
            return
        }

        // From the song cache when it's there (instant), otherwise downloaded straight
        // to disk with top priority; skipped songs' downloads give way to this one.
        let cache = AudioStreamCache.shared
        let key = cache.key(itemId: item.Id, url: url)
        cache.lowerPriority(exceptKey: key)
        isLoading = true
        cache.fetch(url, key: key, urgent: true) { [weak self] file in
            // Superseded by a newer play request or by stop: the cache keeps the file, nothing plays.
            guard let self, self.loadGeneration == generation else { return }
            self.isLoading = false
            guard let file else {
                print("Download failed for \(item.Name)")
                self.isPlaying = false
                self.wantsToPlay = false
                return
            }
            self.fileLoaded(file)
        }
    }

    /// The song's file is here. It is opened, and started only if the user still wants it:
    /// paused while loading, it stays ready so that play starts it at once.
    private func fileLoaded(_ file: URL) {
        guard openFile(at: file) else {
            isPlaying = false
            wantsToPlay = false
            return
        }
        if wantsToPlay { resumePlayback() }
        prefetchNext()
        topUpAutoplay()
    }

    /// Fetches the next song of the queue while this one plays, so "next" and the
    /// automatic advance start without waiting.
    private func prefetchNext() {
        guard let next = upNext.first,
              let url = streamURLProvider?(next.Id), !url.isFileURL else { return }
        let cache = AudioStreamCache.shared
        cache.prefetch(url, key: cache.key(itemId: next.Id, url: url))
    }

    /// Opens the song's file and wires the engine for its format. Nothing plays here.
    private func openFile(at url: URL) -> Bool {
        do {
            let audioFile = try openAudioFile(at: url)
            guard eqManager.reconnect(withFormat: audioFile.processingFormat) else {
                print("Audio engine refused the format \(audioFile.processingFormat)")
                return false
            }
            currentAudioFile = audioFile
            isQueued = false
            seekOffset = 0
            scheduledStartFrame = 0
            return true
        } catch {
            print("Failed to open audio file: \(error)")
            return false
        }
    }

    /// Cache files are named without an extension (stream URLs have none), and
    /// AVAudioFile can't always guess the type of a big MP3 from its content: such a
    /// file is opened through a hard link named with its real extension.
    private func openAudioFile(at url: URL) throws -> AVAudioFile {
        let typedFirst = !Self.knownAudioExtensions.contains(url.pathExtension.lowercased())
        var typedTried = false
        if typedFirst, let typed = typedLink(for: url) {
            typedTried = true
            if let file = try? AVAudioFile(forReading: typed) { return file }
            print("Typed link did not open, trying the original file")
        }
        do {
            return try AVAudioFile(forReading: url)
        } catch {
            print("Plain open failed: \(error)")
            guard !typedTried, let typed = typedLink(for: url) else { throw error }
            print("Retrying through typed link")
            return try AVAudioFile(forReading: typed)
        }
    }

    private static let knownAudioExtensions: Set<String> = [
        "mp3", "flac", "m4a", "mp4", "aac", "alac", "wav", "aiff", "aif", "caf", "ogg", "opus"
    ]

    /// A hard link next to the cache file (in AudioStreamCache/typed/) with the extension
    /// of its detected type. Only the current and the previous link are kept.
    private func typedLink(for url: URL) -> URL? {
        guard let ext = Self.detectedAudioExtension(of: url) else { return nil }
        let folder = url.deletingLastPathComponent().appendingPathComponent("typed", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).\(ext)")
        try? FileManager.default.removeItem(at: link)
        do {
            try FileManager.default.linkItem(at: url, to: link)
        } catch {
            print("Hard link failed (\(error)), copying")
            do {
                try FileManager.default.copyItem(at: url, to: link)
            } catch {
                print("Typed copy failed: \(error)")
                return nil
            }
        }
        let keep: Set<String> = [link.lastPathComponent, previousTypedLink?.lastPathComponent ?? ""]
        for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where !keep.contains(old.lastPathComponent) {
            try? FileManager.default.removeItem(at: old)
        }
        previousTypedLink = link
        return link
    }

    /// Reads the first 12 bytes to tell the audio type apart; nil if it's not recognised.
    private static func detectedAudioExtension(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 12), data.count >= 4 else { return nil }
        let b = [UInt8](data)
        func text(_ range: Range<Int>) -> String? {
            guard range.upperBound <= b.count else { return nil }
            return String(bytes: b[range], encoding: .ascii)
        }
        if text(0..<3) == "ID3" { return "mp3" }
        if b[0] == 0xFF, (b[1] & 0xE0) == 0xE0 { return "mp3" }
        if text(0..<4) == "fLaC" { return "flac" }
        if text(4..<8) == "ftyp" { return "m4a" }
        if text(0..<4) == "RIFF", text(8..<12) == "WAVE" { return "wav" }
        if text(0..<4) == "FORM", ["AIFF", "AIFC"].contains(text(8..<12) ?? "") { return "aiff" }
        if text(0..<4) == "caff" { return "caf" }
        if text(0..<4) == "OggS" { return "ogg" }
        return nil
    }

    /// Queues the whole file on the player node. The node makes no sound until play() is
    /// called, so a file queued here can wait for the user. AVAudioEngine raises (rather
    /// than throws) on a stopped engine or a format mismatch: caught here, it stops this
    /// song instead of the whole app.
    private func queueFromStart(_ audioFile: AVAudioFile) -> Bool {
        playbackGeneration += 1
        let gen = playbackGeneration
        if let exception = AmpfinCatchException({
            playerNode.stop()
            playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.playbackGeneration == gen else { return }
                    self.handlePlaybackCompletion()
                }
            }
        }) {
            print("Failed to queue playback – \(exception.name.rawValue): \(exception.reason ?? "")")
            return false
        }
        seekOffset = 0
        scheduledStartFrame = 0
        isQueued = true

        // Refresh audio info
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.refreshAudioOutputInfo()
        }
        return true
    }

    private func handlePlaybackCompletion() {
        guard isPlaying else { return }

        switch repeatMode {
        case .one:
            if let currentItem = currentlyPlayingItem {
                play(item: currentItem, in: playQueue)
            }
        case .all:
            guard let currentItem = currentlyPlayingItem,
                  let currentIndex = playQueue.firstIndex(where: { $0.id == currentItem.id }) else { return }
            let nextIndex = currentIndex + 1
            if nextIndex < playQueue.count {
                play(item: playQueue[nextIndex], in: playQueue)
            } else if !playQueue.isEmpty {
                play(item: playQueue[0], in: playQueue)
            } else {
                stop()
            }
        case .off:
            forward()
        }
    }

    // MARK: - Queue editing

    /// "Riproduci dopo": right after the current song, in this order. With nothing
    /// playing, the songs start now. A song already further down the queue moves up.
    func playNext(_ items: [AudioItem]) {
        insert(items, afterCurrent: true)
    }

    /// "Aggiungi alla coda": at the end of the queue.
    func addToQueue(_ items: [AudioItem]) {
        insert(items, afterCurrent: false)
    }

    /// Takes a song out of what's coming up (never the one playing).
    func removeFromQueue(_ item: AudioItem) {
        guard item.id != currentlyPlayingItem?.id else { return }
        playQueue.removeAll { $0.id == item.id }
        prefetchNext()
    }

    private func insert(_ items: [AudioItem], afterCurrent: Bool) {
        guard let current = currentlyPlayingItem,
              playQueue.contains(where: { $0.id == current.id }) else {
            if let first = items.first { play(item: first, in: items) }
            return
        }
        // Songs are found by id in the queue, so each may appear only once.
        let adding = items.filter { $0.id != current.id }
        let ids = Set(adding.map(\.id))
        var queue = playQueue.filter { !ids.contains($0.id) }
        let index = queue.firstIndex { $0.id == current.id } ?? queue.count - 1
        if afterCurrent {
            queue.insert(contentsOf: adding, at: index + 1)
        } else {
            queue.append(contentsOf: adding)
        }
        playQueue = queue
        prefetchNext()
    }

    func playAlbumShuffled(tracks: [AudioItem]) {
        guard !tracks.isEmpty else { return }
        let shuffledQueue = tracks.shuffled()
        play(item: shuffledQueue.first!, in: shuffledQueue)
        isShuffled = true
        originalQueue = tracks
    }

    // MARK: - Shuffle and autoplay

    /// Shuffles the songs after the current one; off again, they go back in the order
    /// they had. The song playing never changes.
    func toggleShuffle() {
        guard let current = currentlyPlayingItem,
              let index = playQueue.firstIndex(where: { $0.id == current.id }) else { return }
        if isShuffled {
            let original = originalQueue ?? playQueue
            let present = Set(playQueue.map(\.id))
            // The original order, then anything added while shuffled.
            var restored = original.filter { present.contains($0.id) }
            let known = Set(restored.map(\.id))
            restored += playQueue.filter { !known.contains($0.id) }
            playQueue = restored
            originalQueue = nil
            isShuffled = false
        } else {
            originalQueue = playQueue
            let played = Array(playQueue[...index])
            playQueue = played + playQueue[(index + 1)...].shuffled()
            isShuffled = true
            // With one song or none ahead, there's nothing to mix: autoplay brings some.
            topUpAutoplay()
        }
        prefetchNext()
    }

    /// Keeps a few songs ahead when autoplay is on: when fewer than two are left, adds
    /// up to 15 songs similar to the current one that aren't in the queue yet.
    private func topUpAutoplay() {
        guard autoplayEnabled, repeatMode == .off, upNext.count < 2,
              let current = currentlyPlayingItem, let similarProvider, autoplayTask == nil else { return }
        autoplayTask = Task { @MainActor in
            defer { autoplayTask = nil }
            let similar = await similarProvider(current)
            guard currentlyPlayingItem?.id == current.id, upNext.count < 2 else { return }
            let present = Set(playQueue.map(\.id))
            var adding = similar.filter { !present.contains($0.id) }
            if isShuffled { adding.shuffle() }
            adding = Array(adding.prefix(15))
            guard !adding.isEmpty else { return }
            playQueue += adding
            autoplayIds.formUnion(adding.map(\.id))
            prefetchNext()
        }
    }

    private func removeAutoplayItems() {
        guard !autoplayIds.isEmpty else { return }
        let current = currentlyPlayingItem?.id
        playQueue.removeAll { autoplayIds.contains($0.id) && $0.id != current }
        autoplayIds = []
    }

    func togglePlayPause() {
        if wantsToPlay {
            pause()
        } else {
            resumePlayback()
        }
    }

    func play() {
        resumePlayback()
    }

    func pause() {
        // First, so a song still downloading doesn't start when it arrives.
        wantsToPlay = false
        // Also when the system already stopped the engine (a call): the state, the lock
        // screen and the Dynamic Island must still say paused.
        guard currentlyPlayingItem != nil else { return }
        playerNode.pause()
        isPlaying = false
        stopTimeUpdater()
        updateNowPlayingInfo()
    }

    private func resumePlayback() {
        guard currentlyPlayingItem != nil else { return }
        guard let audioFile = currentAudioFile else {
            if isLoading {
                // Still downloading: fileLoaded starts it.
                wantsToPlay = true
                isPlaying = true
            } else if let item = currentlyPlayingItem {
                // The download failed: play tries it again.
                play(item: item, in: playQueue)
            }
            return
        }
        wantsToPlay = true
        if !isQueued {
            // Opened while paused, or just loaded: queue it from the start. The engine
            // starts first, as the node needs it running.
            activateAudioSession()
            guard eqManager.startEngine(), queueFromStart(audioFile) else {
                markPausedAfterFailedStart()
                return
            }
        }
        guard startPlayerNode() else {
            markPausedAfterFailedStart()
            return
        }
        isPlaying = true
        startTimeUpdater()
        updateNowPlayingInfo()
    }

    /// Takes the audio session, starts the engine and the player node. The node raises an
    /// Objective-C exception when the engine is stopped (after a call or an output change
    /// the engine may not start again): that aborted the app on 07/10, from the play button.
    private func startPlayerNode() -> Bool {
        activateAudioSession()
        guard eqManager.startEngine() else { return false }
        if let exception = AmpfinCatchException({ self.playerNode.play() }) {
            print("Could not start the player – \(exception.name.rawValue): \(exception.reason ?? "")")
            return false
        }
        return true
    }

    /// The engine would not start: show paused, so the next tap tries again.
    private func markPausedAfterFailedStart() {
        wantsToPlay = false
        isPlaying = false
        stopTimeUpdater()
        updateNowPlayingInfo()
    }

    func forward() {
        guard let currentItem = currentlyPlayingItem,
              let currentIndex = playQueue.firstIndex(where: { $0.id == currentItem.id }) else { return }

        let nextIndex = currentIndex + 1
        if nextIndex < playQueue.count {
            play(item: playQueue[nextIndex], in: playQueue)
        } else {
            stop()
        }
    }

    func backward() {
        guard let currentItem = currentlyPlayingItem,
              let currentIndex = playQueue.firstIndex(where: { $0.id == currentItem.id }) else { return }

        if currentTime > 3 {
            seek(to: 0)
        } else {
            let prevIndex = currentIndex - 1
            if prevIndex >= 0 {
                play(item: playQueue[prevIndex], in: playQueue)
            } else {
                seek(to: 0)
            }
        }
    }

    func seek(to time: TimeInterval) {
        guard let audioFile = currentAudioFile else { return }

        let sampleRate = audioFile.processingFormat.sampleRate
        let totalFrames = AVAudioFrameCount(audioFile.length)
        let targetFrame = AVAudioFramePosition(time * sampleRate)
        let clampedFrame = max(0, min(targetFrame, AVAudioFramePosition(totalFrames)))
        let remainingFrames = AVAudioFrameCount(AVAudioFramePosition(totalFrames) - clampedFrame)

        guard remainingFrames > 0 else { return }

        // A song loaded while paused may find the engine stopped: the node needs it running
        // to take the segment, and AVAudioEngine raises (not throws) when it isn't.
        activateAudioSession()
        guard eqManager.startEngine() else {
            markPausedAfterFailedStart()
            return
        }
        playbackGeneration += 1
        let gen = playbackGeneration
        seekOffset = time
        scheduledStartFrame = clampedFrame
        if let exception = AmpfinCatchException({
            playerNode.stop()
            playerNode.scheduleSegment(audioFile, startingFrame: clampedFrame, frameCount: remainingFrames, at: nil) { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.playbackGeneration == gen else { return }
                    self.handlePlaybackCompletion()
                }
            }
        }) {
            print("Failed to seek – \(exception.name.rawValue): \(exception.reason ?? "")")
            markPausedAfterFailedStart()
            return
        }
        isQueued = true
        // Moving the position while paused stays paused, as in Apple Music.
        guard wantsToPlay else {
            currentTime = time
            updateNowPlayingInfo()
            return
        }
        guard startPlayerNode() else {
            markPausedAfterFailedStart()
            return
        }
        isPlaying = true
        startTimeUpdater()
        updateNowPlayingInfo()
    }

    func stop() {
        playedReportTask?.cancel()
        downloadTask?.cancel()
        downloadTask = nil
        // Cancels a download still in progress: it will not start the song.
        loadGeneration += 1
        wantsToPlay = false
        isLoading = false
        isQueued = false
        playbackGeneration += 1
        playerNode.stop()
        stopTimeUpdater()
        currentAudioFile = nil
        currentlyPlayingItem = nil
        isPlaying = false
        currentTime = 0
        seekOffset = 0
        cleanupTempFile()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Time Tracking

    private func startTimeUpdater() {
        stopTimeUpdater()
        timeUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateCurrentTime()
        }
    }

    private func stopTimeUpdater() {
        timeUpdateTimer?.invalidate()
        timeUpdateTimer = nil
    }

    private func updateCurrentTime() {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              let audioFile = currentAudioFile else { return }

        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate > 0 else { return }
        currentTime = seekOffset + Double(playerTime.sampleTime) / sampleRate
    }

    // MARK: - Temp File

    private func cleanupTempFile() {
        if let tempFile = currentTempFile {
            try? FileManager.default.removeItem(at: tempFile)
            currentTempFile = nil
        }
    }

    // MARK: - Private

    private func configureAudioSessionIfNeeded() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        } catch {
            print("AVAudioSession setup failed: \(error)")
        }
        #endif
    }

    /// Takes the audio back before every start. It was done once at launch, so after a
    /// call or another app's sound the session stayed inactive: no Dynamic Island, and
    /// the lock screen controls went to the other app.
    private func activateAudioSession() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AVAudioSession activation failed: \(error)")
        }
        #endif
    }

    private func updateNowPlayingInfo() {
        guard let item = currentlyPlayingItem else { return }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.Name,
            MPMediaItemPropertyAlbumTitle: item.Album ?? "",
            MPMediaItemPropertyArtist: item.mainArtistName ?? "",
            MPMediaItemPropertyPlaybackDuration: item.duration ?? 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]

        if let artworkURLProvider {
            let albumIdOrItemId = item.AlbumId ?? item.Id
            if let artworkUrl = artworkURLProvider(albumIdOrItemId, 400) {
                if let cached = cachedNowPlayingArtworkImage {
                    let artwork = makeArtwork(from: cached)
                    info[MPMediaItemPropertyArtwork] = artwork
                } else {
                    Task.detached(priority: .userInitiated) { [weak self] in
                        guard let self else { return }
                        do {
                            let (data, _) = try await JellyfinAPIService.urlSession.data(from: artworkUrl)
                            guard let platform = PlatformImage(data: data) else { return }
                            await MainActor.run {
                                self.cachedNowPlayingArtworkImage = platform
                                self.updateNowPlayingInfo()
                            }
                        } catch {}
                    }
                }
            }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func makeArtwork(from image: PlatformImage) -> MPMediaItemArtwork {
        #if os(macOS)
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        #else
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        #endif
    }

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        // Headphones, CarPlay and the Dynamic Island often send this one instead of play/pause.
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.currentlyPlayingItem != nil else { return .noActionableNowPlayingItem }
            self.togglePlayPause()
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: event.positionTime)
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.forward()
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.backward()
            return .success
        }
    }

    // MARK: - Audio Output Info

    /// Refreshes all audio output info properties from the current player item and audio session.
    func refreshAudioOutputInfo() {
        updateCodecInfo()
        updateBitrateAndSampleRate()
        updateOutputDevice()
        updateDeviceOutputInfo()
    }

    private func updateCodecInfo() {
        guard let item = currentlyPlayingItem else {
            currentCodec = ""
            isDirectStream = true
            return
        }
        if let container = item.MediaSources?.first?.Container?.uppercased() {
            currentCodec = container
        } else {
            currentCodec = ""
        }
        isDirectStream = true
    }

    private func updateBitrateAndSampleRate() {
        guard currentAudioFile != nil else {
            currentBitrate = 0
            currentSampleRate = 0
            return
        }

        // 1. Try Jellyfin API metadata first (most reliable)
        if let mediaSource = currentlyPlayingItem?.MediaSources?.first {
            if let apiBitrate = mediaSource.Bitrate, apiBitrate > 0 {
                currentBitrate = Double(apiBitrate) / 1000.0
            }
            if let audioStream = mediaSource.MediaStreams?.first(where: { $0.Codec != nil }) {
                if currentBitrate == 0, let streamBitrate = audioStream.BitRate, streamBitrate > 0 {
                    currentBitrate = Double(streamBitrate) / 1000.0
                }
                if let sr = audioStream.SampleRate, sr > 0 {
                    currentSampleRate = Double(sr)
                }
            }
        }

        // 2. Fallback: sample rate from the audio file
        if currentSampleRate == 0, let audioFile = currentAudioFile {
            currentSampleRate = audioFile.processingFormat.sampleRate
        }
    }

    private func updateOutputDevice() {
        #if os(iOS)
        let route = AVAudioSession.sharedInstance().currentRoute
        if let output = route.outputs.first {
            currentOutputDevice = output.portName
        } else {
            currentOutputDevice = "Sconosciuto"
        }
        #elseif os(macOS)
        currentOutputDevice = "Mac"
        #endif
    }

    private func updateDeviceOutputInfo() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        deviceSampleRate = session.sampleRate
        deviceOutputChannels = session.outputNumberOfChannels
        deviceOutputLatency = session.outputLatency
        #else
        // On macOS, read from the engine's output node hardware format
        let hwFormat = eqManager.audioEngine.outputNode.outputFormat(forBus: 0)
        deviceSampleRate = hwFormat.sampleRate
        deviceOutputChannels = Int(hwFormat.channelCount)
        deviceOutputLatency = 0
        #endif
    }

    #if os(iOS)
    private func setupRouteChangeObserver() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.updateOutputDevice()
            self?.updateDeviceOutputInfo()
            // Buds out of the ear or out of range: pause instead of going on from the speaker.
            if let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
               AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable,
               self?.isPlaying == true {
                self?.pause()
            }
        }
    }

    private func setupInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self.isInterrupted = true
                self.resumeAfterInterruption = self.isPlaying
                if self.isPlaying { self.pause() }
            case .ended:
                self.isInterrupted = false
                let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
                if self.resumeAfterInterruption && shouldResume {
                    self.resumePlayback()
                }
                self.resumeAfterInterruption = false
            @unknown default:
                break
            }
        }
    }
    #endif
}
