// DRNowPlaying.swift
// The DR of the song playing and of its album, kept ready for the player's badges. The
// player used to look the values up itself (observing the whole DRStore, scanning the
// 9,000 songs for the album on first open), which ran on the main thread in the frames of
// the open animation. Now everything is computed here, off the view hierarchy, whenever the
// song, the library or the measurements change; the badges only read two integers.

import Foundation
import Combine
import Observation

@MainActor
@Observable
final class DRNowPlaying {
    static let shared = DRNowPlaying()

    /// DR of the song playing, nil while unmeasured.
    private(set) var songDR: Int?
    /// Mean DR of the measured songs of its album, nil if none is measured.
    private(set) var albumDR: Int?

    @ObservationIgnored private var itemId: String?
    @ObservationIgnored private var albumId: String?
    /// Track ids of each album, built off the main thread once per library load.
    @ObservationIgnored private var tracksByAlbum: [String: [String]] = [:]
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    private init() {}

    /// Starts following the player and the library of this view model (safe to call again).
    func bind(to viewModel: JellyfinViewModel) {
        cancellables.removeAll()

        viewModel.$currentlyPlayingItem
            .map { ($0?.Id, $0?.AlbumId) }
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] id, albumId in
                self?.itemId = id
                self?.albumId = albumId
                self?.refresh()
            }
            .store(in: &cancellables)

        // The new library arrives in the sink, before `audioItems` is set: use it, not the property.
        viewModel.$audioItems
            .sink { [weak self] items in self?.rebuildIndex(items) }
            .store(in: &cancellables)

        // A burst of measurements (a run over the library) costs one refresh per half second.
        DRStore.shared.$results
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    private func rebuildIndex(_ items: [AudioItem]) {
        indexTask?.cancel()
        indexTask = Task {
            let index = await Task.detached(priority: .utility) {
                var index: [String: [String]] = [:]
                for item in items {
                    if let albumId = item.AlbumId { index[albumId, default: []].append(item.Id) }
                }
                return index
            }.value
            guard !Task.isCancelled else { return }
            tracksByAlbum = index
            refresh()
        }
    }

    /// A handful of dictionary lookups: one for the song, one per track of the album.
    private func refresh() {
        let results = DRStore.shared.results
        let song = itemId.flatMap { results[$0]?.dr }
        let album = albumId.flatMap { DRStore.shared.albumDR(trackIds: tracksByAlbum[$0] ?? []) }
        // Assign only on change, so an unrelated measurement doesn't wake the badges.
        if song != songDR { songDR = song }
        if album != albumDR { albumDR = album }
    }
}
