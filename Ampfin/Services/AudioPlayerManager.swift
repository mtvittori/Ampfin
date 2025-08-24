import Foundation
import AppKit
import AVFoundation
import Combine
import MediaPlayer

class AudioPlayerManager: ObservableObject {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentlyPlayingItem: AudioItem?
    @Published private(set) var currentTime: TimeInterval = 0
    
    public var repeatMode: RepeatMode = .off
    
    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var playQueue: [AudioItem] = []
    
    private var streamURLProvider: ((String) -> URL?)?
    var artworkURLProvider: ((String, Int) -> URL?)?
    
    private var cachedNowPlayingArtworkImage: NSImage?
    
    // Inizializziamo il manager con una funzione che gli fornirà gli URL per lo streaming
    init(streamURLProvider: @escaping (String) -> URL?, artworkURLProvider: ((String, Int) -> URL?)? = nil) {
        self.streamURLProvider = streamURLProvider
        self.artworkURLProvider = artworkURLProvider
        self.setupRemoteCommandCenter()
    }
    
    func play(item: AudioItem, in queue: [AudioItem]) {
        guard let url = streamURLProvider?(item.Id) else {
            print("Errore: URL per lo streaming non valido.")
            return
        }
        
        self.playQueue = queue
        
        stop() // Ferma la riproduzione precedente
        
        player = AVPlayer(url: url)
        player?.play()
        
        currentlyPlayingItem = item
        isPlaying = true
        startTimeObserver()
        setupEndOfPlayNotification()
        updateNowPlayingInfo()
    }

    func playAlbumShuffled(tracks: [AudioItem]) {
        guard !tracks.isEmpty else { return }
        let shuffledQueue = tracks.shuffled()
        play(item: shuffledQueue.first!, in: shuffledQueue)
    }

    func togglePlayPause() {
        guard player != nil else { return }
        isPlaying.toggle()
        if isPlaying {
            player?.play()
        } else {
            player?.pause()
        }
    }
    
    /// Starts playback if possible
    func play() {
        guard let player = player else { return }
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    /// Pauses playback if possible
    func pause() {
        guard let player = player else { return }
        player.pause()
        isPlaying = false
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
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        updateNowPlayingInfo()
    }
    
    func stop() {
        player?.pause()
        player = nil
        currentlyPlayingItem = nil
        isPlaying = false
        stopTimeObserver()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    
    // MARK: - Private Helpers
    private func startTimeObserver() {
        stopTimeObserver()
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentTime = time.seconds
        }
    }
    
    private func stopTimeObserver() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }
    
    private func setupEndOfPlayNotification() {
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            
            switch self.repeatMode {
            case .one:
                self.seek(to: 0)
                if let currentItem = self.currentlyPlayingItem {
                    self.play(item: currentItem, in: self.playQueue)
                }
            case .all:
                guard let currentItem = self.currentlyPlayingItem,
                      let currentIndex = self.playQueue.firstIndex(where: { $0.id == currentItem.id }) else {
                    return
                }
                let nextIndex = currentIndex + 1
                if nextIndex < self.playQueue.count {
                    self.play(item: self.playQueue[nextIndex], in: self.playQueue)
                } else if !self.playQueue.isEmpty {
                    self.play(item: self.playQueue[0], in: self.playQueue)
                } else {
                    self.stop()
                }
            case .off:
                self.forward()
            }
        }
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
        if let artworkURLProvider = artworkURLProvider {
            let albumIdOrItemId = item.AlbumId ?? item.Id
            if let artworkUrl = artworkURLProvider(albumIdOrItemId, 400) {
                var image: NSImage? = nil
                if artworkUrl.isFileURL {
                    image = NSImage(contentsOf: artworkUrl)
                } else if let cached = cachedNowPlayingArtworkImage {
                    image = cached
                }
                if let image = image {
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    info[MPMediaItemPropertyArtwork] = artwork
                } else if !artworkUrl.isFileURL {
                    // Download asynchronously
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        if let data = try? Data(contentsOf: artworkUrl), let image = NSImage(data: data) {
                            DispatchQueue.main.async {
                                self?.cachedNowPlayingArtworkImage = image
                                self?.updateNowPlayingInfo()
                            }
                        }
                    }
                }
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
}
