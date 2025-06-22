import Foundation
import AVFoundation
import Combine

class AudioPlayerManager: ObservableObject {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentlyPlayingItem: AudioItem?
    @Published private(set) var currentTime: TimeInterval = 0
    
    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var playQueue: [AudioItem] = []
    
    private var streamURLProvider: ((String) -> URL?)?
    
    // Inizializziamo il manager con una funzione che gli fornirà gli URL per lo streaming
    init(streamURLProvider: @escaping (String) -> URL?) {
        self.streamURLProvider = streamURLProvider
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
    }
    
    func stop() {
        player?.pause()
        player = nil
        currentlyPlayingItem = nil
        isPlaying = false
        stopTimeObserver()
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
            self?.forward()
        }
    }
}
