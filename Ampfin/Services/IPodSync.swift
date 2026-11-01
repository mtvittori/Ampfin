// IPodSync.swift
// Copies the user's selection (IPodSelection) onto an iPod running Rockbox. This file is the
// part that lives on the main actor: the format setting, the selection turned into songs
// (reusing the library's artist merge and the album's artist for untagged files), and the
// progress the page shows. The copying itself is in IPodWorker.

#if os(macOS)
import Foundation

// MARK: - Format

/// What lossless files become on the iPod. Lossy files (mp3, m4a, aac, ogg, opus) are copied
/// as they are in every case: converting them again would only lose quality.
enum IPodFormat: String, CaseIterable, Identifiable {
    case aac256, aac192, original

    static let storageKey = "ipodFormat"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .aac256: return "AAC 256 kbps (encoder Apple)"
        case .aac192: return "AAC 192 kbps"
        case .original: return "Originale (nessuna conversione)"
        }
    }

    /// Bits per second of the AAC encoder; nil when nothing is converted.
    var bitrate: Int? {
        switch self {
        case .aac256: return 256_000
        case .aac192: return 192_000
        case .original: return nil
        }
    }

    static var current: IPodFormat {
        UserDefaults.standard.string(forKey: storageKey).flatMap(IPodFormat.init(rawValue:)) ?? .aac256
    }
}

// MARK: - Songs

/// A song with everything the sync needs, as plain values so it can leave the main actor.
struct IPodTrack: Sendable, Identifiable {
    let id: String
    let title: String
    /// The performer(s), for the tags.
    let artist: String
    /// Names the folder: the merged album artist, like the Mac's artist list.
    let albumArtist: String
    let album: String?
    let albumId: String?
    let genre: String?
    let year: Int?
    let trackNumber: Int?
    let trackTotal: Int?
    let disc: Int?
    let discCount: Int
    /// Lowercase container of the original ("flac", "mp3", "m4a").
    let container: String?
    let duration: TimeInterval
    let dateCreated: String?

    /// Containers that AVFoundation decodes and that lose nothing: converted to AAC.
    static let convertibleLossless: Set<String> = ["flac", "alac", "wav", "wave", "aif", "aiff"]

    var isConvertibleLossless: Bool { container.map(Self.convertibleLossless.contains) ?? false }

    /// An .m4a is AAC or ALAC; only the file says which.
    var isAmbiguousM4A: Bool { container == "m4a" || container == "mp4" }

    /// File extension of the original, from the container Jellyfin reports.
    var originalExtension: String? {
        guard let container else { return nil }
        switch container {
        case "m4a", "mp4", "m4b", "alac": return "m4a"
        case "ogg", "oga": return "ogg"
        case "wave": return "wav"
        case "aif": return "aiff"
        default: return container
        }
    }

    /// The extension the file will most likely get under `format`.
    func expectedExtension(for format: IPodFormat) -> String {
        if format.bitrate != nil, isConvertibleLossless { return "m4a" }
        return originalExtension ?? "m4a"
    }

    /// Bytes on the iPod, a rough guess: songs are not downloaded to measure them.
    func estimatedBytes(for format: IPodFormat) -> Int64 {
        let seconds = max(duration, 0)
        if isConvertibleLossless {
            // FLAC of CD audio runs around 850 kbps.
            let bitsPerSecond = Double(format.bitrate ?? 850_000)
            return Int64(seconds * bitsPerSecond / 8)
        }
        return Int64(seconds * 256_000 / 8)
    }
}

/// What a selection entry comes to, shown in the list.
struct IPodEntryStats: Equatable {
    var tracks: Int
    var bytes: Int64
}

struct IPodPlaylistJob: Sendable {
    let name: String
    let trackIds: [String]
}

// MARK: - Progress

struct IPodProgress: Sendable {
    enum Phase: Sendable { case preparing, removing, copying, playlists }

    var phase: Phase = .preparing
    var done = 0
    var total = 0
    var currentTitle: String?
    var bytes: Int64 = 0
}

struct IPodSummary: Sendable {
    var added = 0
    var removed = 0
    var skipped = 0
    var errors: [String] = []
    /// Set when the sync stopped before the end: not enough space, iPod unplugged, cancelled.
    var stopReason: String?
}

// MARK: - Store

@MainActor
final class IPodSync: ObservableObject {
    static let shared = IPodSync()

    @Published private(set) var isRunning = false
    @Published private(set) var progress: IPodProgress?
    @Published private(set) var summary: IPodSummary?
    /// Per selection entry (`IPodSelectionEntry.id`), kept up to date by `refreshStats`.
    @Published private(set) var stats: [String: IPodEntryStats] = [:]
    /// The whole selection, a song in two places counted once.
    @Published private(set) var total = IPodEntryStats(tracks: 0, bytes: 0)

    private var task: Task<Void, Never>?
    /// Playlist contents, fetched once per session: the list asks for them at every change.
    private var playlistCache: [String: [AudioItem]] = [:]

    private init() {}

    // MARK: Estimates

    /// Track count and estimated size of every entry and dynamic source, from the library (no
    /// network except the playlists, once).
    func refreshStats(viewModel: JellyfinViewModel) async {
        let format = IPodFormat.current
        let selection = IPodSelection.shared
        let entries = selection.entries
        var byAlbum: [String: [AudioItem]] = [:]
        if entries.contains(where: { $0.kind == .album }) {
            byAlbum = Dictionary(grouping: viewModel.audioItems.filter { $0.AlbumId != nil }, by: { $0.AlbumId! })
        }
        var result: [String: IPodEntryStats] = [:]
        var union: [String: AudioItem] = [:]
        func record(_ key: String, _ items: [AudioItem], counted: Bool = true) {
            result[key] = IPodEntryStats(
                tracks: items.count,
                bytes: items.reduce(0) { $0 + Self.makeTrackLight($1).estimatedBytes(for: format) })
            if counted { for item in items { union[item.Id] = item } }
        }
        for entry in entries {
            let items: [AudioItem]
            switch entry.kind {
            case .artist: items = artistItems(entry, viewModel: viewModel)
            case .album: items = byAlbum[entry.itemId] ?? []
            case .playlist: items = await playlistItems(entry.itemId, viewModel: viewModel)
            }
            record(entry.id, items)
            // A big selection shouldn't hold the main thread for one stretch.
            await Task.yield()
        }
        for source in IPodDynamicSource.allCases {
            // Switched-off sources show their count too, so the user sees what turning one on adds.
            record(source.statsKey, await dynamicItems(source, viewModel: viewModel, api: nil) ?? [],
                   counted: selection.isOn(source))
            await Task.yield()
        }
        stats = result
        total = IPodEntryStats(
            tracks: union.count,
            bytes: union.values.reduce(0) { $0 + Self.makeTrackLight($1).estimatedBytes(for: format) })
    }

    /// Only duration and container matter for the size.
    private static func makeTrackLight(_ item: AudioItem) -> IPodTrack {
        IPodTrack(id: item.Id, title: item.Name, artist: "", albumArtist: "", album: nil, albumId: nil,
                  genre: nil, year: nil, trackNumber: nil, trackTotal: nil, disc: nil, discCount: 1,
                  container: item.containerName, duration: item.duration ?? 0, dateCreated: nil)
    }

    // MARK: Selection → songs

    private func artistItems(_ entry: IPodSelectionEntry, viewModel: JellyfinViewModel) -> [AudioItem] {
        // The id of a merged artist is the one of its best photo and can change with the merge
        // rules: the name finds it again.
        guard let artist = viewModel.artists.first(where: { $0.Id == entry.itemId }) ?? viewModel.artist(named: entry.name) else { return [] }
        return viewModel.tracks(byArtist: artist)
    }

    /// nil when the server can't be asked and nothing is cached.
    private func fetchPlaylist(_ id: String, viewModel: JellyfinViewModel, fresh: Bool) async -> [AudioItem]? {
        if !fresh, let cached = playlistCache[id] { return cached }
        guard let items = try? await viewModel.apiService?.fetchPlaylistItems(playlistId: id) else { return playlistCache[id] }
        playlistCache[id] = items
        return items
    }

    private func playlistItems(_ id: String, viewModel: JellyfinViewModel) async -> [AudioItem] {
        await fetchPlaylist(id, viewModel: viewModel, fresh: false) ?? []
    }

    /// The songs a dynamic source stands for right now. With `api` (a sync) the server is asked
    /// and nil means it couldn't be: the sync must stop. Without it (the page's numbers) the
    /// library and what the Home already loaded are used.
    private func dynamicItems(_ source: IPodDynamicSource, viewModel: JellyfinViewModel,
                              api: JellyfinAPIService?) async -> [AudioItem]? {
        let selection = IPodSelection.shared
        switch source {
        case .favorites:
            // Same as the Favorites page: the songs with a heart, and every song of the albums with one.
            let albumIds = viewModel.favoriteAlbumIds
            let songs = viewModel.favoriteTracks + viewModel.audioItems.filter { $0.AlbumId.map(albumIds.contains) ?? false }
            var seen = Set<String>()
            return songs.filter { seen.insert($0.Id).inserted }
        case .recentAlbums:
            // Same order as the "Aggiunti di recente" page.
            let newest = viewModel.albums
                .sorted { ($0.dateAddedDate ?? .distantPast) > ($1.dateAddedDate ?? .distantPast) }
                .prefix(selection.recentAlbumsCount)
            if newest.isEmpty { return viewModel.audioItems.isEmpty ? nil : [] }
            let ids = Set(newest.map(\.Id))
            let local = Dictionary(grouping: viewModel.audioItems.filter { $0.AlbumId.map(ids.contains) ?? false },
                                   by: { $0.AlbumId! })
            guard let api else { return local.values.flatMap { $0 } }
            var items: [AudioItem] = []
            for album in newest {
                if let fetched = try? await api.fetchAlbumTracks(albumId: album.Id), !fetched.isEmpty {
                    items += fetched
                } else if let known = local[album.Id] {
                    items += known
                } else {
                    return nil
                }
            }
            return items
        case .recentPlayed:
            let count = selection.recentPlayedCount
            guard let api else { return Array(viewModel.recentlyPlayedTracks.prefix(count)) }
            guard let played = try? await api.fetchRecentlyPlayedTracks() else { return nil }
            return Array(played.prefix(count))
        }
    }

    /// Songs of every entry with the full data (track numbers, year), in selection order.
    /// `failed` names the entries that couldn't be read: the sync must not go on then, or the
    /// songs of those entries would look unselected and be taken off the iPod.
    private func resolve(viewModel: JellyfinViewModel) async -> (tracks: [IPodTrack], playlists: [IPodPlaylistJob], failed: [String]) {
        guard let api = viewModel.apiService else { return ([], [], ["server"]) }
        var failed: [String] = []
        // Without the library nothing can be matched, and every song would look unselected.
        let selection = IPodSelection.shared
        if viewModel.audioItems.isEmpty, !selection.entries.isEmpty || !selection.enabledSources.isEmpty {
            return ([], [], ["libreria non ancora caricata"])
        }
        let albumsById = Dictionary(viewModel.albums.map { ($0.Id, $0) }, uniquingKeysWith: { first, _ in first })

        // How many songs and discs each album has in the library, for "3/12" and "disc 1/2".
        var albumSongs: [String: Int] = [:]
        var albumDiscs: [String: Int] = [:]
        for item in viewModel.audioItems {
            guard let albumId = item.AlbumId else { continue }
            albumSongs[albumId, default: 0] += 1
            albumDiscs[albumId] = max(albumDiscs[albumId] ?? 1, item.ParentIndexNumber ?? 1)
        }

        var items: [AudioItem] = []
        var playlists: [IPodPlaylistJob] = []
        for entry in IPodSelection.shared.entries {
            switch entry.kind {
            case .album:
                if let fetched = try? await api.fetchAlbumTracks(albumId: entry.itemId), !fetched.isEmpty {
                    items += fetched
                } else {
                    let local = viewModel.audioItems.filter { $0.AlbumId == entry.itemId }
                    if local.isEmpty { failed.append(entry.name) }
                    items += local
                }
            case .artist:
                let songs = artistItems(entry, viewModel: viewModel)
                if songs.isEmpty { failed.append(entry.name) }
                items += await withNumbers(songs, api: api)
            case .playlist:
                guard let songs = await fetchPlaylist(entry.itemId, viewModel: viewModel, fresh: true) else {
                    failed.append(entry.name)
                    continue
                }
                items += songs
                playlists.append(IPodPlaylistJob(name: entry.name, trackIds: songs.map(\.Id)))
            }
            if Task.isCancelled { break }
        }
        for source in selection.enabledSources {
            guard let songs = await dynamicItems(source, viewModel: viewModel, api: api) else {
                failed.append(source.title)
                continue
            }
            let numbered = await withNumbers(songs, api: api)
            items += numbered
            if !numbered.isEmpty {
                playlists.append(IPodPlaylistJob(name: source.playlistName, trackIds: numbered.map(\.Id)))
            }
            if Task.isCancelled { break }
        }

        var seen = Set<String>()
        var tracks: [IPodTrack] = []
        for item in items where seen.insert(item.Id).inserted {
            let album = item.AlbumId.flatMap { albumsById[$0] }
            let rawAlbumArtist = album?.AlbumArtist ?? item.AlbumArtists?.first?.Name
                ?? viewModel.artistName(for: item) ?? "Artista sconosciuto"
            // The merged name, so "Florence + The Machine" and "Florence + the Machine" share a folder.
            let albumArtist = viewModel.artist(named: rawAlbumArtist)?.Name ?? rawAlbumArtist
            let artist = item.Artists.flatMap { $0.isEmpty ? nil : $0.joined(separator: ", ") } ?? albumArtist
            tracks.append(IPodTrack(
                id: item.Id, title: item.Name, artist: artist, albumArtist: albumArtist,
                album: album?.Name ?? item.Album, albumId: item.AlbumId,
                genre: item.Genres?.first, year: album?.ProductionYear ?? item.ProductionYear,
                trackNumber: item.IndexNumber, trackTotal: item.AlbumId.flatMap { albumSongs[$0] },
                disc: item.ParentIndexNumber, discCount: item.AlbumId.flatMap { albumDiscs[$0] } ?? 1,
                container: item.containerName, duration: item.duration ?? 0, dateCreated: item.DateCreated))
        }
        return (tracks, playlists, failed)
    }

    /// A library cache written before the sync existed has no track numbers: the albums of
    /// those songs are asked to the server.
    private func withNumbers(_ items: [AudioItem], api: JellyfinAPIService) async -> [AudioItem] {
        let missing = Set(items.filter { $0.IndexNumber == nil }.compactMap(\.AlbumId))
        guard !missing.isEmpty else { return items }
        var fresh: [String: AudioItem] = [:]
        for albumId in missing {
            for song in (try? await api.fetchAlbumTracks(albumId: albumId)) ?? [] { fresh[song.Id] = song }
        }
        return items.map { fresh[$0.Id] ?? $0 }
    }

    // MARK: Running

    func start(viewModel: JellyfinViewModel) {
        guard !isRunning else { return }
        let volume = IPodVolume.shared
        volume.refresh()
        guard let root = volume.url, volume.isConnected else {
            summary = IPodSummary(stopReason: "L'iPod non è collegato.")
            return
        }
        guard let api = viewModel.apiService else {
            summary = IPodSummary(stopReason: "Non sei connesso al server.")
            return
        }
        isRunning = true
        summary = nil
        progress = IPodProgress(phase: .preparing)
        let format = IPodFormat.current

        task = Task { [weak self] in
            // A long copy shouldn't be interrupted by the Mac going to sleep.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Sincronizzazione iPod")
            defer { ProcessInfo.processInfo.endActivity(activity) }

            guard let self else { return }
            let resolved = await self.resolve(viewModel: viewModel)
            if !resolved.failed.isEmpty {
                self.finish(IPodSummary(stopReason: "Non riesco a leggere dal server: \(resolved.failed.joined(separator: ", ")). Non tocco l'iPod."))
                return
            }
            if Task.isCancelled {
                self.finish(IPodSummary(stopReason: "Sincronizzazione annullata."))
                return
            }
            let worker = IPodWorker(
                volume: root, format: format, tracks: resolved.tracks, playlists: resolved.playlists, api: api,
                progress: { snapshot in
                    DispatchQueue.main.async { MainActor.assumeIsolated { IPodSync.shared.progress = snapshot } }
                })
            let result = await worker.run()
            self.finish(result)
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func finish(_ result: IPodSummary) {
        summary = result
        progress = nil
        isRunning = false
        task = nil
        IPodVolume.shared.refresh()
    }
}
#endif
