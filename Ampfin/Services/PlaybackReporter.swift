// PlaybackReporter.swift
// Tells Jellyfin what is playing, the way the official apps do: a session starts once a
// song has played a few seconds, sends its position every 10 seconds and at every
// pause, and stops with the real position when the song changes or ends.
// Before, Ampfin sent start and stop in the same instant: the play counted, but the
// Playback Reporting plugin recorded nothing, so there was no history to build on.

import Combine
import Foundation

@MainActor
final class PlaybackReporter {
    private let api: JellyfinAPIService
    private var cancellables = Set<AnyCancellable>()
    private var ticker: Task<Void, Never>?

    /// The song whose session is open on the server, if any.
    private var session: (itemId: String, id: String)?
    private var position: TimeInterval = 0
    private var isPaused = false

    init(api: JellyfinAPIService, player: AudioPlayerManager) {
        self.api = api
        player.$currentTime
            .sink { [weak self] time in self?.position = time }
            .store(in: &cancellables)
        player.$isPlaying
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] playing in self?.playingChanged(playing) }
            .store(in: &cancellables)
        player.$currentlyPlayingItem
            .map { $0?.Id }
            .removeDuplicates()
            .sink { [weak self] itemId in self?.itemChanged(itemId) }
            .store(in: &cancellables)
    }

    /// The song has played long enough to count (the player waits a few seconds, so
    /// skipping through doesn't fill the history). Throws when the server can't be reached.
    func start(itemId: String) async throws {
        if let session, session.itemId == itemId { return }
        await stopSession()
        let id = UUID().uuidString
        session = (itemId, id)
        isPaused = false
        try await api.reportPlaybackStart(itemId: itemId, sessionId: id, position: position)
        startTicker()
    }

    private func itemChanged(_ itemId: String?) {
        guard let session, session.itemId != itemId else { return }
        // `position` still holds where the previous song got to: the end, if it finished.
        let last = position
        self.session = nil
        ticker?.cancel()
        Task { try? await api.reportPlaybackStopped(itemId: session.itemId, sessionId: session.id, position: last) }
    }

    private func playingChanged(_ playing: Bool) {
        isPaused = !playing
        sendProgress()
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                // While paused one update every 10 s keeps the session alive on the server.
                self?.sendProgress()
            }
        }
    }

    private func sendProgress() {
        guard let session else { return }
        let position = position, paused = isPaused
        Task { try? await api.reportPlaybackProgress(itemId: session.itemId, sessionId: session.id,
                                                     position: position, isPaused: paused) }
    }

    private func stopSession() async {
        guard let session else { return }
        self.session = nil
        ticker?.cancel()
        try? await api.reportPlaybackStopped(itemId: session.itemId, sessionId: session.id, position: position)
    }
}
