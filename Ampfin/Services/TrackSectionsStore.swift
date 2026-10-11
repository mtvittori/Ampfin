// TrackSectionsStore.swift
// The Brani list, sorted and grouped by letter (or month) once per library load and sort, in
// a background task, and kept across tab switches. Sorting 9.700 songs with
// localizedStandardCompare is ~70 ms: on the main thread at every visit it was a hitch.

import Foundation

/// One finished list. A class: rows hold a reference (their play queue) and compare it by
/// identity instead of copying or comparing thousands of songs.
final class TrackSectionsResult {
    let sort: TrackSort
    let sections: [LetterSection<AudioItem>]
    /// Plays in the order on screen, "#" included.
    let queue: [AudioItem]

    init(sort: TrackSort, sections: [LetterSection<AudioItem>], queue: [AudioItem]) {
        self.sort = sort
        self.sections = sections
        self.queue = queue
    }

    static let empty = TrackSectionsResult(sort: .name, sections: [], queue: [])

    /// Letters mean nothing in date order: month headers instead, and no index.
    var showsLetters: Bool { sort != .added }
}

@MainActor
final class TrackSectionsStore: ObservableObject {
    static let shared = TrackSectionsStore()

    /// What a list depends on. `library` is `JellyfinViewModel.libraryRevision`.
    struct Key: Hashable {
        let library: Int
        let sort: TrackSort
        let query: String
    }

    /// Bumped when a build lands, so the screen showing the previous list redraws.
    @Published private(set) var revision = 0

    private var results: [Key: TrackSectionsResult] = [:]
    private var recent: [Key] = []
    private var building: Set<Key> = []
    private var newestLibrary = -1
    /// The last list built: shown while the one for a new sort or search is being made.
    private(set) var latest = TrackSectionsResult.empty

    /// The list for `key` when it is ready, else the last one built (possibly of another sort).
    func result(for key: Key) -> TrackSectionsResult { results[key] ?? latest }

    /// Starts the build for `key` unless it is done or on its way.
    func ensure(_ key: Key, tracks: [AudioItem], names: ArtistNameLookup) {
        guard results[key] == nil, !building.contains(key) else { return }
        building.insert(key)
        let task = Task.detached(priority: .userInitiated) {
            Self.build(key: key, tracks: tracks, names: names)
        }
        Task { finish(key, await task.value) }
    }

    /// After a library load: the saved sort is ready before the tab is first opened.
    func prewarm(tracks: [AudioItem], names: ArtistNameLookup, revision: Int) {
        let sort = UserDefaults.standard.string(forKey: "tracksSort").flatMap(TrackSort.init) ?? .name
        ensure(Key(library: revision, sort: sort, query: ""), tracks: tracks, names: names)
    }

    private func finish(_ key: Key, _ result: TrackSectionsResult) {
        building.remove(key)
        // A list of an older library is of no use.
        guard key.library >= newestLibrary else { return }
        if key.library > newestLibrary {
            newestLibrary = key.library
            results = [:]
            recent = []
        }
        results[key] = result
        recent.removeAll { $0 == key }
        recent.append(key)
        // The three sorts and a search at most: each holds two copies of the songs.
        if recent.count > 4 { results[recent.removeFirst()] = nil }
        latest = result
        revision += 1
    }

    private nonisolated static func build(key: Key, tracks: [AudioItem], names: ArtistNameLookup) -> TrackSectionsResult {
        let query = key.query
        let filtered = query.isEmpty ? tracks : tracks.filter {
            $0.Name.localizedCaseInsensitiveContains(query) ||
            ($0.mainArtistName ?? "").localizedCaseInsensitiveContains(query) ||
            ($0.Album ?? "").localizedCaseInsensitiveContains(query)
        }
        // Song id to artist name, built once for the sort.
        let artists = key.sort == .artist
            ? Dictionary(filtered.map { ($0.Id, names.name(for: $0) ?? "") }, uniquingKeysWith: { first, _ in first })
            : [:]
        let sorted = key.sort.sorted(filtered, artists: artists)
        let sections: [LetterSection<AudioItem>]
        switch key.sort {
        case .name: sections = LetterIndex.sections(sorted, name: \.Name)
        case .artist: sections = LetterIndex.sections(sorted) { artists[$0.Id] ?? "" }
        case .added: sections = TrackSort.monthSections(sorted)
        }
        return TrackSectionsResult(sort: key.sort, sections: sections, queue: sections.flatMap(\.items))
    }
}
