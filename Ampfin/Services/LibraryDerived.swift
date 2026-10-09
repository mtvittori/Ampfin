// LibraryDerived.swift
// What the app works out from a library load (genres, merged artists, lookups for the
// mixes and the statistics). Thousands of songs: it is built in a detached task and then
// handed to the view model in one go, so the main thread only assigns.

import Foundation

/// The artist shown for a song: its own tag, or for untagged files the album's artist.
struct ArtistNameLookup {
    /// Album id → album artist.
    var byAlbum: [String: String] = [:]

    func name(for item: AudioItem) -> String? {
        if let name = item.mainArtistName { return name }
        return item.AlbumId.flatMap { byAlbum[$0] }
    }
}

struct LibraryDerived {
    let tracks: [AudioItem]
    /// Newest first.
    let albums: [AlbumItem]
    let rawArtists: [ArtistItem]
    let genres: [String]
    let artistIndex: ArtistIndex
    let artistNames: ArtistNameLookup
    /// The library's songs as the statistics want them, by `normalizedId`: the id
    /// clean-up alone was ~10 ms of the main thread at every load of the statistics.
    let scrobbleTracks: [String: ScrobbleTrack]

    /// `genres` are the ones saved with a cache; without them they are read off the songs.
    static func make(tracks: [AudioItem], albums: [AlbumItem], rawArtists: [ArtistItem],
                     genres: [String]?) async -> LibraryDerived {
        await Task.detached(priority: .userInitiated) {
            let newestFirst = albums.sortedNewestFirst(by: \.dateAddedDate)
            var lookup = ArtistNameLookup()
            lookup.byAlbum = Dictionary(newestFirst.compactMap { album in album.AlbumArtist.map { (album.Id, $0) } },
                                        uniquingKeysWith: { first, _ in first })
            var scrobble: [String: ScrobbleTrack] = [:]
            scrobble.reserveCapacity(tracks.count)
            for item in tracks {
                scrobble[ScrobbleStatsBuilder.normalizedId(item.Id)] = ScrobbleTrack(
                    id: item.Id, title: item.Name, artist: lookup.name(for: item) ?? "",
                    album: item.Album, albumId: item.AlbumId, duration: item.duration)
            }
            return LibraryDerived(
                tracks: tracks, albums: newestFirst, rawArtists: rawArtists,
                genres: genres ?? Array(Set(tracks.compactMap(\.Genres).flatMap { $0 })).sorted(),
                // Its own copy of the merge rules: the shared one belongs to the main thread.
                artistIndex: ArtistIndex(raw: rawArtists, rules: ArtistMergeStore()),
                artistNames: lookup, scrobbleTracks: scrobble)
        }.value
    }
}
