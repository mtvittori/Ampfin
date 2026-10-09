// ScrobbleStats.swift
// Listening statistics in the style of last.fm: listens per week, month, year and in all,
// with the top artists, albums and tracks. The listens come from the Playback Reporting
// plugin, which records every listen with its date and how long it played. Without the
// plugin they're worked out from the play counts and last play dates Jellyfin keeps for
// each song, and marked as approximate.

import Foundation

enum ScrobblePeriod: String, CaseIterable, Identifiable {
    case week, month, year, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .week: return "7 giorni"
        case .month: return "30 giorni"
        case .year: return "12 mesi"
        case .all: return "Sempre"
        }
    }
}

/// One listen ("scrobble").
struct Scrobble: Identifiable, Hashable {
    let id: String             // unique per listen
    let itemId: String         // Jellyfin track id
    let title: String
    let artist: String
    let album: String?
    let albumId: String?       // for the cover: api.artworkURL(for: albumId ?? itemId)
    let date: Date
}

/// A row of a top chart (artist, album or track) with its play count.
struct ScrobbleCount: Identifiable, Hashable {
    let id: String             // artist name / album id / track id
    let name: String
    let subtitle: String?      // artist for albums and tracks, nil for artists
    let imageItemId: String?   // item whose Primary image to show (album id, or artist item id if known)
    let count: Int
    /// Places gained against the previous period (+2 up, -1 down, 0 same); nil = not ranked before, or "all".
    var rankChange: Int? = nil
    /// Not in the previous period's list at all ("all": false).
    var isNew: Bool = false
}

struct ScrobbleSummary {
    let period: ScrobblePeriod
    let totalScrobbles: Int
    let listeningTime: TimeInterval
    let uniqueArtists: Int
    let uniqueTracks: Int
    let topArtists: [ScrobbleCount]   // up to 50, most played first
    let topAlbums: [ScrobbleCount]
    let topTracks: [ScrobbleCount]
    let byHour: [Int]                 // 24 values, listens per hour of day (local time)
    let byDay: [(day: Date, count: Int)] // one entry per day of the period (all: per month), oldest first
    let isApproximate: Bool           // true when built from play counts, not real listen dates
    let previousTotal: Int?           // listens in the period just before, same length (nil for .all)
    let previousListeningTime: TimeInterval?
    let topHour: Int?                 // hour of day with most listens (nil without listens)
}

/// A song as the statistics need it.
struct ScrobbleTrack {
    let id: String
    let title: String
    let artist: String
    let album: String?
    let albumId: String?
    let duration: TimeInterval?
    /// Plays Jellyfin counts for this user (only for the songs of the listening history).
    var playCount = 0
    var lastPlayed: Date?
}

@MainActor
final class ScrobbleStatsStore: ObservableObject {
    static let shared = ScrobbleStatsStore()
    /// Settings → Home: show the "Le tue statistiche" section on the home. Default false.
    static let homeKey = "scrobbleStatsOnHome"

    @Published private(set) var recent: [Scrobble] = []      // latest listens, newest first (up to 50)
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    /// Listens this calendar day / this week, for the compact home card.
    @Published private(set) var todayCount = 0
    @Published private(set) var weekCount = 0
    /// Consecutive days with a listen, ending today (or yesterday, when nothing is played yet today).
    @Published private(set) var streakDays = 0

    private var summaries: [ScrobblePeriod: ScrobbleSummary] = [:]
    private var loadedAt: Date?
    private var loadedUserId: String?

    /// Reloaded after this long, or when the user changes.
    private static let maxAge: TimeInterval = 300

    func summary(for period: ScrobblePeriod) -> ScrobbleSummary? {
        summaries[period]
    }

    /// Loads (or reloads when `force` or older than 5 minutes) from the server.
    func load(using viewModel: JellyfinViewModel, force: Bool = false) async {
        guard !isLoading, let api = viewModel.apiService else { return }
        let userId = viewModel.currentUserId
        let stale = loadedAt.map { Date().timeIntervalSince($0) > Self.maxAge } ?? true
        guard force || stale || loadedUserId != userId else { return }

        isLoading = true
        defer { isLoading = false }
        do {
            let now = Date()
            // The play counts and last plays of this user: the fallback, and the plays made
            // before the plugin was there. Also the names for the songs of the library.
            let history = try await api.fetchListeningHistory(maxAge: force ? 0 : 120)
            // The library's songs are ready from the load (`scrobbleTracks`); the history adds
            // the play counts. Worked out away from the main thread: ~10.000 ids to clean.
            let libraryTracks = viewModel.scrobbleTracks
            let artistLookup = viewModel.artistNameLookup
            let played = await Task.detached(priority: .utility) {
                var entries: [String: ScrobbleTrack] = [:]
                for item in history {
                    entries[ScrobbleStatsBuilder.normalizedId(item.Id)] = ScrobbleTrack(
                        id: item.Id, title: item.Name, artist: artistLookup.name(for: item) ?? "",
                        album: item.Album, albumId: item.AlbumId, duration: item.duration,
                        playCount: max(item.UserData?.PlayCount ?? 1, 1), lastPlayed: item.UserData?.lastPlayed)
                }
                return entries
            }.value

            // Every listen of the last 12 months, from the plugin.
            let uid = userId.replacingOccurrences(of: "-", with: "").lowercased()
            let cutoff = ScrobbleStatsBuilder.stamp(ScrobbleStatsBuilder.periodStart(.all, now: now))
            let sql = "SELECT DateCreated, ItemId, PlayDuration FROM PlaybackActivity "
                + "WHERE UserId = '\(uid)' AND ItemType = 'Audio' AND DateCreated >= '\(cutoff)' "
                + "ORDER BY DateCreated DESC"
            let rows: [[String]]
            let approximate: Bool
            do {
                rows = try await api.playbackReportingRows(sql: sql)
                approximate = false
            } catch {
                // Any failure (not installed, refusing, unreadable answer, network while iOS asks
                // for the Local Network permission): the play counts are all there is.
                rows = []
                approximate = true
            }

            // Listens of songs no longer in the library or the history: their names come from the server.
            var extra: [String: ScrobbleTrack] = [:]
            let unknown = Set(rows.compactMap { $0.count >= 3 ? ScrobbleStatsBuilder.normalizedId($0[1]) : nil })
                .filter { libraryTracks[$0] == nil && played[$0] == nil }
            if !unknown.isEmpty, let items = try? await api.fetchItems(ids: Array(unknown)) {
                for item in items {
                    extra[ScrobbleStatsBuilder.normalizedId(item.Id)] = track(item, in: viewModel)
                }
            }

            // Thousands of listens: counted away from the main thread.
            let output = await Task.detached(priority: .utility) {
                var tracks = libraryTracks
                tracks.merge(played) { _, new in new }
                tracks.merge(extra) { _, new in new }
                return ScrobbleStatsBuilder.build(tracks: tracks, rows: rows, approximate: approximate, now: now)
            }.value

            // The user may have changed while this was loading.
            guard viewModel.currentUserId == userId else { return }
            summaries = output.summaries
            recent = output.recent
            todayCount = output.todayCount
            weekCount = output.weekCount
            streakDays = output.streakDays
            loadedAt = Date()
            loadedUserId = userId
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// After logging out, nothing of the previous user stays.
    func reset() {
        summaries = [:]
        recent = []
        todayCount = 0
        weekCount = 0
        streakDays = 0
        loadedAt = nil
        loadedUserId = nil
        lastError = nil
    }

    private func track(_ item: AudioItem, in viewModel: JellyfinViewModel) -> ScrobbleTrack {
        ScrobbleTrack(id: item.Id, title: item.Name, artist: viewModel.artistName(for: item) ?? "",
                      album: item.Album, albumId: item.AlbumId, duration: item.duration)
    }
}

/// Turns the plugin's rows, or the play counts, into the summaries. Nothing here touches
/// the main actor, so it runs in a detached task.
enum ScrobbleStatsBuilder {
    /// One counted listen.
    struct Listen {
        let track: ScrobbleTrack
        let date: Date
        let seconds: TimeInterval
    }

    struct Output {
        let summaries: [ScrobblePeriod: ScrobbleSummary]
        let recent: [Scrobble]
        let todayCount: Int
        let weekCount: Int
        let streakDays: Int
    }

    /// Jellyfin ids come with and without dashes, in either case.
    static func normalizedId(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Local time, as the plugin writes DateCreated.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// First day of the period. Week, month and year are the last 7, 30 and 365 days;
    /// all is the last 12 months.
    static func periodStart(_ period: ScrobblePeriod, now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        func daysBack(_ days: Int) -> Date {
            calendar.date(byAdding: .day, value: -days, to: today) ?? today
        }
        switch period {
        case .week: return daysBack(6)
        case .month: return daysBack(29)
        case .year: return daysBack(364)
        case .all:
            let month = calendar.dateInterval(of: .month, for: now)?.start ?? today
            return calendar.date(byAdding: .month, value: -11, to: month) ?? month
        }
    }

    /// Last.fm's rule: a listen counts when it played half the song or four minutes,
    /// whichever comes first. Without the duration, thirty seconds.
    static func countsAsListen(seconds: TimeInterval, duration: TimeInterval?) -> Bool {
        guard let duration, duration > 0 else { return seconds >= 30 }
        return seconds >= min(duration / 2, 240)
    }

    /// `tracks` are keyed by `normalizedId`. `rows` are the plugin's rows: DateCreated, ItemId,
    /// PlayDuration. Without the plugin (`approximate`), each song counts once at its last
    /// play, and the other plays of the play count are undated.
    static func build(tracks: [String: ScrobbleTrack], rows: [[String]], approximate: Bool, now: Date) -> Output {
        let calendar = Calendar.current
        var listens: [Listen] = []
        // Plays with no date: only the "all" period counts them.
        var extras: [(track: ScrobbleTrack, count: Int)] = []

        if approximate {
            for track in tracks.values where track.playCount > 0 {
                var undated = track.playCount
                if let last = track.lastPlayed {
                    listens.append(Listen(track: track, date: last, seconds: track.duration ?? 0))
                    undated -= 1
                }
                if undated > 0 { extras.append((track: track, count: undated)) }
            }
        } else {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.dateFormat = "yyyy-MM-dd HH:mm:ss"
            // Every row is a play the server recorded, whether or not it counts as a listen.
            var plays: [String: Int] = [:]
            var playDates: [String: [Date]] = [:]
            for row in rows where row.count >= 3 {
                let key = normalizedId(row[1])
                plays[key, default: 0] += 1
                guard let date = parser.date(from: String(row[0].prefix(19))) else { continue }
                playDates[key, default: []].append(date)
                guard let track = tracks[key] else { continue }
                let seconds = Double(row[2]) ?? 0
                guard countsAsListen(seconds: seconds, duration: track.duration) else { continue }
                listens.append(Listen(track: track, date: date, seconds: seconds))
            }
            // Plays from before the plugin (or outside its 12 months) are in the play count only.
            // Songs the plugin never saw count too. Before 7 October Ampfin didn't report to the
            // plugin, so those listens are only in the play count: the last one has a date
            // (Jellyfin's last play), unless the plugin recorded it, and goes in its day.
            for (key, track) in tracks where track.playCount > plays[key, default: 0] {
                var undated = track.playCount - plays[key, default: 0]
                if let last = track.lastPlayed,
                   !(playDates[key] ?? []).contains(where: { abs($0.timeIntervalSince(last)) < 120 }) {
                    listens.append(Listen(track: track, date: last, seconds: track.duration ?? 0))
                    undated -= 1
                }
                if undated > 0 { extras.append((track: track, count: undated)) }
            }
        }

        listens.sort { $0.date > $1.date }
        var summaries: [ScrobblePeriod: ScrobbleSummary] = [:]
        for period in ScrobblePeriod.allCases {
            summaries[period] = summarize(period, listens: listens, extras: extras, now: now,
                                          approximate: approximate, calendar: calendar)
        }

        let todayStart = calendar.startOfDay(for: now)
        let todayCount = listens.prefix(while: { $0.date >= todayStart }).count
        let recent = listens.prefix(50).enumerated().map { index, listen in
            Scrobble(id: "\(index)", itemId: listen.track.id, title: listen.track.title,
                     artist: listen.track.artist, album: listen.track.album,
                     albumId: listen.track.albumId, date: listen.date)
        }
        return Output(summaries: summaries, recent: recent, todayCount: todayCount,
                      weekCount: summaries[.week]?.totalScrobbles ?? 0,
                      streakDays: streak(listens, now: now, calendar: calendar))
    }

    /// Consecutive days with a listen, ending today or, when nothing is played yet today, yesterday.
    static func streak(_ listens: [Listen], now: Date, calendar: Calendar) -> Int {
        let days = Set(listens.map { calendar.startOfDay(for: $0.date) })
        var day = calendar.startOfDay(for: now)
        if !days.contains(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while days.contains(day), let previous = calendar.date(byAdding: .day, value: -1, to: day) {
            count += 1
            day = previous
        }
        return count
    }

    /// Days in the window before the period, which the "previous" numbers come from.
    private static func windowDays(_ period: ScrobblePeriod) -> Int? {
        switch period {
        case .week: return 7
        case .month: return 30
        case .year: return 365
        case .all: return nil
        }
    }

    /// What the listens of one window add up to, before they're ranked.
    private struct Tally {
        var total = 0
        var time: TimeInterval = 0
        var plays: [String: Int] = [:]           // normalized track id → listens
        var tracks: [String: ScrobbleTrack] = [:]
        var hours = Array(repeating: 0, count: 24)
        var buckets: [Date: Int] = [:]           // day (or month) start → listens
    }

    /// Counts the listens inside `window`. Only dated listens: the extras are added by the caller.
    private static func tally(_ listens: [Listen], component: Calendar.Component, calendar: Calendar,
                              in window: (Date) -> Bool) -> Tally {
        var result = Tally()
        for listen in listens where window(listen.date) {
            result.total += 1
            result.time += listen.seconds
            let key = normalizedId(listen.track.id)
            result.plays[key, default: 0] += 1
            result.tracks[key] = listen.track
            result.hours[calendar.component(.hour, from: listen.date)] += 1
            let bucket = calendar.dateInterval(of: component, for: listen.date)?.start ?? listen.date
            result.buckets[bucket, default: 0] += 1
        }
        return result
    }

    /// Plays with no date (the "all" period only).
    private static func addExtras(_ extras: [(track: ScrobbleTrack, count: Int)], to result: inout Tally) {
        for extra in extras {
            let key = normalizedId(extra.track.id)
            result.total += extra.count
            result.time += Double(extra.count) * (extra.track.duration ?? 0)
            result.plays[key, default: 0] += extra.count
            result.tracks[key] = extra.track
        }
    }

    /// Songs, artists and albums of a window, most played first (ties by name).
    private struct Rankings {
        let artists: [ScrobbleCount]
        let albums: [ScrobbleCount]
        let tracks: [ScrobbleCount]
    }

    private static func rankings(_ result: Tally) -> Rankings {
        let rows = result.plays.compactMap { key, count -> (track: ScrobbleTrack, count: Int)? in
            guard let track = result.tracks[key] else { return nil }
            return (track: track, count: count)
        }
        .sorted { a, b in a.count != b.count ? a.count > b.count : a.track.title < b.track.title }

        var tracks: [ScrobbleCount] = []
        var artistCounts: [String: Int] = [:]
        var artistImage: [String: String] = [:]
        var albumCounts: [String: (name: String, artist: String, count: Int)] = [:]
        for row in rows {
            let track = row.track
            tracks.append(ScrobbleCount(id: track.id, name: track.title,
                                        subtitle: track.artist.isEmpty ? nil : track.artist,
                                        imageItemId: track.albumId ?? track.id, count: row.count))
            if !track.artist.isEmpty {
                artistCounts[track.artist, default: 0] += row.count
                // Rows come most played first, so the first song of an artist gives its picture.
                if artistImage[track.artist] == nil {
                    artistImage[track.artist] = track.albumId ?? track.id
                }
            }
            if let albumId = track.albumId, let album = track.album {
                var entry = albumCounts[albumId] ?? (name: album, artist: track.artist, count: 0)
                entry.count += row.count
                albumCounts[albumId] = entry
            }
        }
        let artists = artistCounts.map { entry in
            ScrobbleCount(id: entry.key, name: entry.key, subtitle: nil,
                          imageItemId: artistImage[entry.key], count: entry.value)
        }
        let albums = albumCounts.map { entry in
            ScrobbleCount(id: entry.key, name: entry.value.name,
                          subtitle: entry.value.artist.isEmpty ? nil : entry.value.artist,
                          imageItemId: entry.key, count: entry.value.count)
        }
        return Rankings(artists: sortedByCount(artists), albums: sortedByCount(albums), tracks: tracks)
    }

    private static func sortedByCount(_ rows: [ScrobbleCount]) -> [ScrobbleCount] {
        rows.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    /// Place of each row in a ranking, by id (first place is 1).
    private static func places(_ rows: [ScrobbleCount]) -> [String: Int] {
        Dictionary(rows.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { first, _ in first })
    }

    /// The top 50 of a ranking, with the change of place against the previous window
    /// (`previous` nil: nothing to compare with).
    private static func chart(_ rows: [ScrobbleCount], previous: [String: Int]?) -> [ScrobbleCount] {
        rows.prefix(50).enumerated().map { index, row in
            var row = row
            if let previous {
                if let before = previous[row.id] {
                    row.rankChange = before - (index + 1)
                } else {
                    row.isNew = true
                }
            }
            return row
        }
    }

    private static func summarize(_ period: ScrobblePeriod, listens: [Listen],
                                  extras: [(track: ScrobbleTrack, count: Int)], now: Date,
                                  approximate: Bool, calendar: Calendar) -> ScrobbleSummary {
        let start = periodStart(period, now: now, calendar: calendar)
        // Day buckets for week, month and year; month buckets for all.
        let component: Calendar.Component = period == .all ? .month : .day

        // "All" is not cut by date: the approximate listens are one per song, dated at the last play.
        var current = tally(listens, component: component, calendar: calendar) {
            period == .all || $0 >= start
        }
        if period == .all {
            addExtras(extras, to: &current)
        }
        let currentRanks = rankings(current)

        // The window just before, of the same length: only for the periods that have one.
        var previousTotal: Int?
        var previousTime: TimeInterval?
        var previousRanks: Rankings?
        if let days = windowDays(period),
           let previousStart = calendar.date(byAdding: .day, value: -days, to: start) {
            let previous = tally(listens, component: component, calendar: calendar) {
                $0 >= previousStart && $0 < start
            }
            previousTotal = previous.total
            previousTime = previous.time
            previousRanks = rankings(previous)
        }

        let topHour: Int? = {
            guard current.total > 0 else { return nil }
            // Ties go to the earlier hour.
            return current.hours.enumerated().max { a, b in
                a.element != b.element ? a.element < b.element : a.offset > b.offset
            }?.offset
        }()

        // Every day (or month) from the start to now, zeros included.
        var days: [(day: Date, count: Int)] = []
        let last = calendar.dateInterval(of: component, for: now)?.start ?? now
        var cursor = calendar.dateInterval(of: component, for: start)?.start ?? start
        while cursor <= last {
            days.append((day: cursor, count: current.buckets[cursor] ?? 0))
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
            cursor = next
        }

        return ScrobbleSummary(
            period: period, totalScrobbles: current.total, listeningTime: current.time,
            uniqueArtists: currentRanks.artists.count, uniqueTracks: current.tracks.count,
            topArtists: chart(currentRanks.artists, previous: previousRanks.map { places($0.artists) }),
            topAlbums: chart(currentRanks.albums, previous: previousRanks.map { places($0.albums) }),
            topTracks: chart(currentRanks.tracks, previous: previousRanks.map { places($0.tracks) }),
            byHour: current.hours, byDay: days, isApproximate: approximate,
            previousTotal: previousTotal, previousListeningTime: previousTime, topHour: topHour
        )
    }
}
