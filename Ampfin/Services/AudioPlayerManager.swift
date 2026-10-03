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
    private var timeUpdateTimer: Timer?
    private var scheduledStartFrame: AVAudioFramePosition = 0
    private var seekOffset: TimeInterval = 0
    /// Incremented each time we schedule new audio; stale completion handlers are ignored.
    private var playbackGeneration: Int = 0

    private var playQueue: [AudioItem] = []

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

    #if os(iOS)
    private var routeChangeObserver: NSObjectProtocol?
    #endif

    init(streamURLProvider: @escaping (String) -> URL?, artworkURLProvider: ((String, Int) -> URL?)? = nil) {
        self.streamURLProvider = streamURLProvider
        self.artworkURLProvider = artworkURLProvider
        configureAudioSessionIfNeeded()
        setupRemoteCommandCenter()
        #if os(iOS)
        setupRouteChangeObserver()
        #endif
    }

    // MARK: - Playback

    func play(item: AudioItem, in queue: [AudioItem]) {
        guard let url = streamURLProvider?(item.Id) else {
            print("Errore: URL per lo streaming non valido.")
            return
        }

        self.playQueue = queue
        stop()

        cachedNowPlayingArtworkImage = nil
        currentlyPlayingItem = item
        isPlaying = true
        updateNowPlayingInfo()
        scheduleReportPlayed(for: item)

        // Download audio to temp file, then play via AVAudioEngine
        downloadAndPlay(url: url, item: item)
    }

    /// Reports the item as played once it's had a few seconds of genuine playback,
    /// so skipping through tracks quickly doesn't pollute "recently played".
    private func scheduleReportPlayed(for item: AudioItem) {
        playedReportTask?.cancel()
        playedReportTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled, self.currentlyPlayingItem?.Id == item.Id else { return }
            do {
                try await self.markPlayedProvider?(item.Id)
                await MainActor.run { self.onDidReportPlayed?(item) }
            } catch {
                // Non-critical — "recently played" simply won't reflect this listen.
            }
        }
    }

    private func downloadAndPlay(url: URL, item: AudioItem) {
        // Cancel any ongoing download
        downloadTask?.cancel()

        // If it's a local file, play directly
        if url.isFileURL {
            playAudioFile(at: url)
            return
        }

        // Download to temp file
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("ampfin_stream_\(item.Id).\(url.pathExtension.isEmpty ? "audio" : url.pathExtension)")

        // Clean previous temp file
        cleanupTempFile()

        let request = URLRequest(url: url)
        downloadTask = JellyfinAPIService.urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self, let data, error == nil else {
                DispatchQueue.main.async {
                    if self?.currentlyPlayingItem?.Id == item.Id {
                        print("Download failed: \(error?.localizedDescription ?? "unknown")")
                        self?.isPlaying = false
                    }
                }
                return
            }

            do {
                try data.write(to: tempFile, options: .atomic)
                DispatchQueue.main.async {
                    guard self.currentlyPlayingItem?.Id == item.Id else { return }
                    self.currentTempFile = tempFile
                    self.playAudioFile(at: tempFile)
                }
            } catch {
                print("Failed to write temp file: \(error)")
                DispatchQueue.main.async {
                    self.isPlaying = false
                }
            }
        }
        downloadTask?.resume()
    }

    private func playAudioFile(at url: URL) {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            currentAudioFile = audioFile

            let format = audioFile.processingFormat
            eqManager.reconnect(withFormat: format)
            eqManager.startEngine()

            seekOffset = 0
            scheduledStartFrame = 0
            playbackGeneration += 1
            let gen = playbackGeneration
            playerNode.stop()
            playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.playbackGeneration == gen else { return }
                    self.handlePlaybackCompletion()
                }
            }
            playerNode.play()
            isPlaying = true
            startTimeUpdater()
            updateNowPlayingInfo()

            // Refresh audio info
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.refreshAudioOutputInfo()
            }
        } catch {
            print("Failed to open audio file: \(error)")
            isPlaying = false
        }
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

    func playAlbumShuffled(tracks: [AudioItem]) {
        guard !tracks.isEmpty else { return }
        let shuffledQueue = tracks.shuffled()
        play(item: shuffledQueue.first!, in: shuffledQueue)
    }

    func togglePlayPause() {
        guard currentAudioFile != nil else { return }
        if isPlaying {
            pause()
        } else {
            resumePlayback()
        }
    }

    func play() {
        resumePlayback()
    }

    func pause() {
        guard audioEngine.isRunning else { return }
        playerNode.pause()
        isPlaying = false
        stopTimeUpdater()
        updateNowPlayingInfo()
    }

    private func resumePlayback() {
        guard currentAudioFile != nil else { return }
        if !audioEngine.isRunning {
            eqManager.startEngine()
        }
        playerNode.play()
        isPlaying = true
        startTimeUpdater()
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

        playbackGeneration += 1
        let gen = playbackGeneration
        playerNode.stop()
        seekOffset = time
        scheduledStartFrame = clampedFrame

        playerNode.scheduleSegment(audioFile, startingFrame: clampedFrame, frameCount: remainingFrames, at: nil) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.playbackGeneration == gen else { return }
                self.handlePlaybackCompletion()
            }
        }
        playerNode.play()
        isPlaying = true
        startTimeUpdater()
        updateNowPlayingInfo()
    }

    func stop() {
        playedReportTask?.cancel()
        downloadTask?.cancel()
        downloadTask = nil
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
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("AVAudioSession setup failed: \(error)")
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
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
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
        ) { [weak self] _ in
            self?.updateOutputDevice()
            self?.updateDeviceOutputInfo()
        }
    }
    #endif
}
