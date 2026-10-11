// DRRankingStore.swift
// The rows of "Classifica DR" (songs or albums, ranking or search), built off the main thread
// and kept between visits: opening the page shows the last list at once, and a rebuild runs
// only when the results, the library, the mode or the search changed.

import Foundation

struct DRSongRow: Identifiable {
    let item: AudioItem
    let artist: String
    /// nil while the song has no measurement (only shown in search results).
    let dr: Int?
    /// Position in the ranking; nil in search results.
    var rank: Int?
    var id: String { item.Id }
}

struct DRAlbumRow: Identifiable {
    let album: AlbumItem
    let tracks: [AudioItem]
    let dr: Int?
    let measured: Int
    var rank: Int?
    /// "n/m misurati", when it is worth saying.
    let note: String?
    var id: String { album.Id }
}

enum DRRankingMode: String, CaseIterable, Identifiable {
    case songs = "Brani", albums = "Album"
    var id: String { rawValue }
}

/// What the search looks into, folded (case and accents) once per library change so a keystroke
/// only runs `contains` over 8,000 short strings. Built inside the background rebuild.
struct DRSearchIndex {
    /// What the keys were made from; another value means the library changed.
    struct Key: Equatable {
        let library: Int
        let items: Int
        let albums: Int
        let artists: Int
    }

    var key: Key?
    /// Parallel to the library's songs and albums; nil until a search in that mode needs them.
    var songKeys: [String]?
    var albumKeys: [String]?

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The words of the query; a key matches when it holds all of them.
    static func terms(_ query: String) -> [String] {
        fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func matches(_ key: String, _ terms: [String]) -> Bool {
        terms.allSatisfy { key.contains($0) }
    }
}

@MainActor
final class DRRankingStore: ObservableObject {
    static let shared = DRRankingStore()

    @Published private(set) var songs: [DRSongRow] = []
    @Published private(set) var albums: [DRAlbumRow] = []
    /// The songs of `songs`, in order: the queue a tap plays.
    private(set) var queue: [AudioItem] = []
    /// Measured songs of the library and their mean DR, worked out with the rows.
    @Published private(set) var measured = 0
    @Published private(set) var meanDR: Int?
    /// True while a rebuild runs, so the page can tell "still working" from "nothing here".
    @Published private(set) var isBuilding = false
    /// Counts the finished builds: the page refreshes its selection on a change.
    @Published private(set) var builds = 0

    /// What each list was built from. Equal to the wanted key: nothing to do.
    private var songsKey: Key?
    private var albumsKey: Key?
    private var pendingKey: Key?
    private var searchIndex = DRSearchIndex()
    private var task: Task<Void, Never>?

    private struct Key: Equatable {
        let mode: DRRankingMode
        let query: String
        let results: Int
        /// Catches a value replaced by a new measurement or an import, which keeps the count.
        let checksum: Int
        let library: Int
        let items: Int
        let albums: Int
    }

    private struct Input {
        let mode: DRRankingMode
        let query: String
        let results: [String: DRResult]
        let items: [AudioItem]
        let albums: [AlbumItem]
        let artists: ArtistNameLookup
        let index: DRSearchIndex
        let indexKey: DRSearchIndex.Key
    }

    private struct Output {
        var songs: [DRSongRow] = []
        var albums: [DRAlbumRow] = []
        var measured = 0
        var meanDR: Int?
        var index: DRSearchIndex
    }

    /// Whether the list of this mode was built at least once (else the page shows a spinner,
    /// not "nothing measured").
    func hasBuilt(_ mode: DRRankingMode) -> Bool {
        (mode == .songs ? songsKey : albumsKey) != nil
    }

    /// Builds the list for these inputs unless it already is the one shown.
    func refresh(mode: DRRankingMode, query: String, results: [String: DRResult], items: [AudioItem],
                 albums: [AlbumItem], artists: ArtistNameLookup, libraryRevision: Int) {
        let key = Key(mode: mode, query: query, results: results.count,
                      checksum: results.values.reduce(0) { $0 &+ Int($1.value * 10) },
                      library: libraryRevision, items: items.count, albums: albums.count)
        guard key != (mode == .songs ? songsKey : albumsKey), key != pendingKey else { return }
        task?.cancel()
        pendingKey = key
        isBuilding = true
        let input = Input(mode: mode, query: query, results: results, items: items, albums: albums,
                          artists: artists, index: searchIndex,
                          indexKey: DRSearchIndex.Key(library: libraryRevision, items: items.count,
                                                      albums: albums.count, artists: artists.byAlbum.count))
        task = Task {
            let output = await Task.detached(priority: .userInitiated) { Self.build(input) }.value
            guard !Task.isCancelled else { return }
            switch mode {
            case .songs:
                songs = output.songs
                queue = output.songs.map(\.item)
                songsKey = key
            case .albums:
                self.albums = output.albums
                albumsKey = key
            }
            measured = output.measured
            meanDR = output.meanDR
            searchIndex = output.index
            pendingKey = nil
            isBuilding = false
            builds += 1
        }
    }

    // MARK: Build (off the main thread)

    private struct SongEntry {
        let index: Int
        let artist: String
        let dr: Int?
        /// Lowercased "artist album title", so the sort never compares localized strings.
        let sortKey: String
    }

    private struct AlbumEntry {
        let index: Int
        let tracks: [AudioItem]
        let dr: Int?
        let measured: Int
        let sortKey: String
    }

    private nonisolated static func build(_ input: Input) -> Output {
        let results = input.results
        let items = input.items
        var count = 0
        var sum = 0.0
        for item in items {
            if let result = results[item.Id] { count += 1; sum += result.value }
        }
        var output = Output(measured: count, meanDR: count == 0 ? nil : Int((sum / Double(count)).rounded()),
                            index: input.index)
        if output.index.key != input.indexKey { output.index = DRSearchIndex(key: input.indexKey) }
        let terms = DRSearchIndex.terms(input.query)

        switch input.mode {
        case .songs:
            var entries: [SongEntry] = []
            if terms.isEmpty {
                // The ranking: measured songs only.
                for (index, item) in items.enumerated() {
                    if let result = results[item.Id] { entries.append(songEntry(index, item, result.dr, input.artists)) }
                }
            } else {
                // Search: the whole library, measured or not.
                if output.index.songKeys == nil {
                    output.index.songKeys = items.map {
                        DRSearchIndex.fold("\(input.artists.name(for: $0) ?? "") \($0.Album ?? "") \($0.Name)")
                    }
                }
                let keys = output.index.songKeys ?? []
                for (index, item) in items.enumerated() where DRSearchIndex.matches(keys[index], terms) {
                    entries.append(songEntry(index, item, results[item.Id]?.dr, input.artists))
                }
            }
            entries.sort { precedes($0.dr, $0.sortKey, $0.index, $1.dr, $1.sortKey, $1.index) }
            output.songs = entries.enumerated().map { position, entry in
                DRSongRow(item: items[entry.index], artist: entry.artist, dr: entry.dr,
                          rank: terms.isEmpty ? position + 1 : nil)
            }
        case .albums:
            let albums = input.albums
            let byAlbum = Dictionary(grouping: items, by: { $0.AlbumId ?? "" })
            var entries: [AlbumEntry] = []
            if terms.isEmpty {
                for (index, album) in albums.enumerated() {
                    guard let tracks = byAlbum[album.Id],
                          let entry = albumEntry(index, album, tracks, results), entry.dr != nil else { continue }
                    entries.append(entry)
                }
            } else {
                if output.index.albumKeys == nil {
                    output.index.albumKeys = albums.map { DRSearchIndex.fold("\($0.AlbumArtist ?? "") \($0.Name)") }
                }
                let keys = output.index.albumKeys ?? []
                for (index, album) in albums.enumerated() where DRSearchIndex.matches(keys[index], terms) {
                    if let entry = albumEntry(index, album, byAlbum[album.Id] ?? [], results) { entries.append(entry) }
                }
            }
            entries.sort { precedes($0.dr, $0.sortKey, $0.index, $1.dr, $1.sortKey, $1.index) }
            output.albums = entries.enumerated().map { position, entry in
                let album = albums[entry.index]
                let total = entry.tracks.count
                // The ranking says it only for partial albums; search always does.
                let note = total > 0 && (!terms.isEmpty || entry.measured < total) ? "\(entry.measured)/\(total) misurati" : nil
                return DRAlbumRow(album: album, tracks: entry.tracks, dr: entry.dr, measured: entry.measured,
                                  rank: terms.isEmpty ? position + 1 : nil, note: note)
            }
        }
        return output
    }

    private nonisolated static func songEntry(_ index: Int, _ item: AudioItem, _ dr: Int?,
                                              _ artists: ArtistNameLookup) -> SongEntry {
        let artist = artists.name(for: item) ?? ""
        return SongEntry(index: index, artist: artist, dr: dr,
                         sortKey: "\(artist)\u{0}\(item.Album ?? "")\u{0}\(item.Name)".lowercased())
    }

    /// The album DR is the rounded mean of its measured songs (as `DRStore.albumDR`), nil if none.
    private nonisolated static func albumEntry(_ index: Int, _ album: AlbumItem, _ tracks: [AudioItem],
                                               _ results: [String: DRResult]) -> AlbumEntry? {
        var done = 0
        var sum = 0.0
        for track in tracks {
            if let result = results[track.Id] { done += 1; sum += result.value }
        }
        let dr = done == 0 ? nil : Int((sum / Double(done)).rounded())
        return AlbumEntry(index: index, tracks: tracks, dr: dr, measured: done,
                          sortKey: "\(album.AlbumArtist ?? "")\u{0}\(album.Name)".lowercased())
    }

    /// Most dynamic first, the unmeasured last, then by name (library order breaks the ties).
    private nonisolated static func precedes(_ lhs: Int?, _ lhsKey: String, _ lhsIndex: Int,
                                             _ rhs: Int?, _ rhsKey: String, _ rhsIndex: Int) -> Bool {
        let (a, b) = (lhs ?? -1, rhs ?? -1)
        if a != b { return a > b }
        return lhsKey != rhsKey ? lhsKey < rhsKey : lhsIndex < rhsIndex
    }
}
