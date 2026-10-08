// MixEngine.swift
// The mixes Ampfin works out by itself for the user who is logged in, from what that
// user listens to on Jellyfin (play count and last play of each song): every user of
// the server gets their own. They change once a day: the random choices are seeded with
// the user and the date, so the same day gives the same mixes.

import Foundation

struct Mix: Identifiable {
    enum Kind: String {
        case daily, rediscover, top, fresh, discover, genre
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let tracks: [AudioItem]

    /// Up to four different albums, for the cover.
    var coverAlbumIds: [String] {
        var seen = Set<String>()
        return tracks.compactMap(\.AlbumId).filter { seen.insert($0).inserted }.prefix(4).map { $0 }
    }
}

enum MixEngine {
    struct Input {
        let library: [AudioItem]
        /// The user's played songs, with UserData.
        let history: [AudioItem]
        let favoriteTrackIds: Set<String>
        /// Recently added albums, newest first.
        let recentAlbumIds: [String]
        /// Song id → artist shown for it (untagged songs take the album's artist).
        let artistNames: [String: String]
        let userKey: String
        let day: String
    }

    static let size = 25

    static func mixes(_ input: Input) -> [Mix] {
        let scores = Scores(input)
        var result: [Mix] = []
        if let mix = daily(input, scores) { result.append(mix) }
        if let mix = top(input, scores) { result.append(mix) }
        if let mix = rediscover(input, scores) { result.append(mix) }
        if let mix = fresh(input, scores) { result.append(mix) }
        if let mix = discover(input, scores) { result.append(mix) }
        result += genres(input, scores)
        return result
    }

    // MARK: - Taste

    /// How much the user likes each artist and genre: plays, weighted towards the last weeks.
    private struct Scores {
        var artist: [String: Double] = [:]
        var genre: [String: Double] = [:]
        var track: [String: Double] = [:]
        var played: Set<String> = []

        init(_ input: Input) {
            let now = Date()
            for item in input.history {
                let plays = Double(max(item.UserData?.PlayCount ?? 1, 1))
                let days = item.UserData?.lastPlayed.map { now.timeIntervalSince($0) / 86_400 } ?? 365
                let score = plays * (0.3 + exp(-max(days, 0) / 30))
                track[item.Id] = score
                played.insert(item.Id)
                if let name = input.artistNames[item.Id], !name.isEmpty { artist[name, default: 0] += score }
                for g in item.Genres ?? [] { genre[g, default: 0] += score }
            }
            // Favorites count as liked even before they're played much.
            for item in input.library where input.favoriteTrackIds.contains(item.Id) {
                if let name = input.artistNames[item.Id], !name.isEmpty { artist[name, default: 0] += 2 }
            }
        }

        func topArtists(_ n: Int) -> [String] {
            artist.sorted { $0.value > $1.value }.prefix(n).map(\.key)
        }

        func topGenres(_ n: Int) -> [String] {
            genre.sorted { $0.value > $1.value }.prefix(n).map(\.key)
        }
    }

    // MARK: - The mixes

    /// The user's artists of the moment: some of their songs heard most, some not yet.
    private static func daily(_ input: Input, _ scores: Scores) -> Mix? {
        var rng = MixRandom(input.userKey, input.day, "daily")
        let candidates = scores.topArtists(12)
        guard !candidates.isEmpty else { return favoritesOnly(input) }
        let artists = weightedSample(candidates, count: 7, weight: { scores.artist[$0] ?? 0 }, rng: &rng)
        let byArtist = Dictionary(grouping: input.library) { input.artistNames[$0.Id] ?? "" }

        var picks: [AudioItem] = []
        for artist in artists {
            let songs = byArtist[artist] ?? []
            let loved = songs.filter { scores.played.contains($0.Id) }
                .sorted { (scores.track[$0.Id] ?? 0) > (scores.track[$1.Id] ?? 0) }
            let others = songs.filter { !scores.played.contains($0.Id) }.shuffled(using: &rng)
            picks += Array(loved.prefix(6).shuffled(using: &rng).prefix(2)) + Array(others.prefix(2))
        }
        let favorites = input.library.filter { input.favoriteTrackIds.contains($0.Id) }.shuffled(using: &rng)
        picks += favorites.prefix(4)
        let tracks = spaced(unique(picks).shuffled(using: &rng), input.artistNames).prefix(size)
        guard tracks.count >= 8 else { return nil }
        return Mix(id: "daily", kind: .daily, title: "Mix del giorno",
                   subtitle: names(of: Array(tracks), input.artistNames), tracks: Array(tracks))
    }

    /// When nothing has been played yet: the favorites, shuffled for the day.
    private static func favoritesOnly(_ input: Input) -> Mix? {
        var rng = MixRandom(input.userKey, input.day, "daily")
        let favorites = input.library.filter { input.favoriteTrackIds.contains($0.Id) }.shuffled(using: &rng)
        guard favorites.count >= 8 else { return nil }
        let tracks = Array(favorites.prefix(size))
        return Mix(id: "daily", kind: .daily, title: "Mix del giorno",
                   subtitle: names(of: tracks, input.artistNames), tracks: tracks)
    }

    private static func top(_ input: Input, _ scores: Scores) -> Mix? {
        let tracks = input.history
            .sorted {
                let a = $0.UserData?.PlayCount ?? 0, b = $1.UserData?.PlayCount ?? 0
                return a != b ? a > b : (scores.track[$0.Id] ?? 0) > (scores.track[$1.Id] ?? 0)
            }
            .prefix(size)
        guard tracks.count >= 8 else { return nil }
        return Mix(id: "top", kind: .top, title: "I più ascoltati",
                   subtitle: "Le canzoni che hai ascoltato più volte", tracks: Array(tracks))
    }

    /// Songs played several times that haven't come back for a while.
    private static func rediscover(_ input: Input, _ scores: Scores) -> Mix? {
        var rng = MixRandom(input.userKey, input.day, "rediscover")
        let cutoff = Date().addingTimeInterval(-45 * 86_400)
        let old = input.history.filter {
            ($0.UserData?.PlayCount ?? 0) >= 2 && ($0.UserData?.lastPlayed ?? .distantPast) < cutoff
        }
        .sorted { ($0.UserData?.PlayCount ?? 0) > ($1.UserData?.PlayCount ?? 0) }
        let tracks = spaced(Array(old.prefix(80)).shuffled(using: &rng), input.artistNames).prefix(size)
        guard tracks.count >= 8 else { return nil }
        return Mix(id: "rediscover", kind: .rediscover, title: "Da riscoprire",
                   subtitle: "Ti piacevano, non le ascolti da un po'", tracks: Array(tracks))
    }

    /// Unplayed songs from the latest albums, the user's artists first.
    private static func fresh(_ input: Input, _ scores: Scores) -> Mix? {
        let order = Dictionary(input.recentAlbumIds.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let songs = input.library.filter { item in
            guard let album = item.AlbumId, order[album] != nil else { return false }
            return !scores.played.contains(item.Id)
        }
        let sorted = songs.sorted {
            let a = scores.artist[input.artistNames[$0.Id] ?? ""] ?? 0
            let b = scores.artist[input.artistNames[$1.Id] ?? ""] ?? 0
            if (a > 0) != (b > 0) { return a > 0 }
            return (order[$0.AlbumId ?? ""] ?? 0) < (order[$1.AlbumId ?? ""] ?? 0)
        }
        // A few songs per album, so one long album doesn't fill it.
        var perAlbum: [String: Int] = [:]
        let tracks = sorted.filter { item in
            let key = item.AlbumId ?? ""
            perAlbum[key, default: 0] += 1
            return perAlbum[key]! <= 3
        }.prefix(size)
        guard tracks.count >= 6 else { return nil }
        return Mix(id: "fresh", kind: .fresh, title: "Novità per te",
                   subtitle: "Dagli ultimi album aggiunti", tracks: Array(tracks))
    }

    /// Songs never played, from the user's genres and artists.
    private static func discover(_ input: Input, _ scores: Scores) -> Mix? {
        var rng = MixRandom(input.userKey, input.day, "discover")
        let genres = Set(scores.topGenres(4))
        guard !genres.isEmpty else { return nil }
        let pool = input.library.filter { item in
            !scores.played.contains(item.Id) && !(item.Genres ?? []).filter(genres.contains).isEmpty
        }
        let picked = weightedSample(pool, count: size * 2, weight: { item in
            1 + min(scores.artist[input.artistNames[item.Id] ?? ""] ?? 0, 10)
        }, rng: &rng)
        let tracks = spaced(picked, input.artistNames).prefix(size)
        guard tracks.count >= 8 else { return nil }
        return Mix(id: "discover", kind: .discover, title: "Da scoprire",
                   subtitle: "Mai ascoltate, nei generi che ascolti", tracks: Array(tracks))
    }

    /// One mix for each of the two genres heard most.
    private static func genres(_ input: Input, _ scores: Scores) -> [Mix] {
        scores.topGenres(2).compactMap { genre in
            var rng = MixRandom(input.userKey, input.day, "genre-\(genre)")
            let pool = input.library.filter { $0.Genres?.contains(genre) ?? false }
            let picked = weightedSample(pool, count: size * 2, weight: { item in
                (scores.played.contains(item.Id) ? 3 : 1) + min(scores.artist[input.artistNames[item.Id] ?? ""] ?? 0, 6)
            }, rng: &rng)
            let tracks = spaced(picked, input.artistNames).prefix(size)
            guard tracks.count >= 8 else { return nil }
            return Mix(id: "genre-\(genre)", kind: .genre, title: "Mix \(genre)",
                       subtitle: names(of: Array(tracks), input.artistNames), tracks: Array(tracks))
        }
    }

    // MARK: - Helpers

    private static func unique(_ items: [AudioItem]) -> [AudioItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.Id).inserted }
    }

    /// Keeps two songs of the same artist from following each other where it can.
    private static func spaced(_ items: [AudioItem], _ artists: [String: String]) -> [AudioItem] {
        var rest = unique(items)
        var result: [AudioItem] = []
        while !rest.isEmpty {
            let last = result.last.flatMap { artists[$0.Id] }
            let index = rest.firstIndex { artists[$0.Id] != last } ?? 0
            result.append(rest.remove(at: index))
        }
        return result
    }

    /// "Artist A, Artist B e altri".
    private static func names(of tracks: [AudioItem], _ artists: [String: String]) -> String {
        var seen = Set<String>()
        let list = tracks.compactMap { artists[$0.Id] }.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !list.isEmpty else { return "" }
        let shown = list.prefix(3).joined(separator: ", ")
        return list.count > 3 ? "\(shown) e altri" : shown
    }

    /// `count` different elements, each picked with a chance proportional to its weight.
    private static func weightedSample<T>(_ items: [T], count: Int, weight: (T) -> Double,
                                          rng: inout MixRandom) -> [T] {
        // Efraimidis–Spirakis: key = u^(1/w), keep the largest keys.
        items
            .map { item -> (T, Double) in
                let w = max(weight(item), 0.0001)
                let u = Double.random(in: 0.000001..<1, using: &rng)
                return (item, pow(u, 1 / w))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(count)
            .map(\.0)
    }
}

/// A random generator that gives the same numbers for the same seed (SplitMix64), so a
/// mix stays the same all day.
struct MixRandom: RandomNumberGenerator {
    private var state: UInt64

    init(_ parts: String...) {
        // FNV-1a: Swift's own hashing changes at every launch.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in parts.joined(separator: "|").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        state = hash
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
