// HomeGreeting.swift
// The personal line at the top of the Home, under its title: a short sentence about the user's
// music (an album's anniversary, new albums to hear, the week's top artist, a mix that's ready…).
// With the "Data" style the navigation subtitle is the date instead, and no line is shown.
// Built only from data the app has already loaded.

import SwiftUI

enum HomeSubtitleStyle: String, CaseIterable, Identifiable {
    case message, date

    static let storageKey = "homeSubtitleStyle"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .message: return "Messaggio per te"
        case .date: return "Data"
        }
    }
}

@MainActor
final class HomeGreeting: ObservableObject {
    static let shared = HomeGreeting()

    /// The sentence to show. Only written when it changes, so a refresh doesn't redraw the Home.
    @Published private(set) var line: String
    /// The date, for the "Data" style.
    @Published private(set) var dateLine: String

    /// What can be said right now, best first; `base` is today's pick, `offset` the taps since.
    private var lines: [String] = []
    private var base = 0
    private var offset = 0
    private var slot = -1

    private init() {
        let date = Self.dateText(Date())
        line = date
        dateLine = date
    }

    // MARK: - Public

    /// Recomputes the candidates. The pick is stable within the same hour.
    func refresh(viewModel: JellyfinViewModel, now: Date = Date()) {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .weekday], from: now)
        let hour = parts.hour ?? 12
        let greeting = Self.greeting(hour: hour)

        var candidates: [Candidate] = []
        candidates += anniversaries(viewModel.albums, now: now, calendar: calendar).map { Candidate(priority: 5, weight: 10, fact: $0) }
        if let fact = newMusic(viewModel, now: now) { candidates.append(Candidate(priority: 4, weight: 8, fact: fact)) }
        candidates += stats().map { Candidate(priority: 3, weight: 5, fact: $0) }
        candidates += mixes(hour: hour, weekday: parts.weekday ?? 1).map { Candidate(priority: 2, weight: 4, fact: $0) }
        candidates += mood(hour: hour, weekday: parts.weekday ?? 1).map { Candidate(priority: 2, weight: 3, fact: $0) }
        if let fact = repeatedArtist(viewModel) { candidates.append(Candidate(priority: 2, weight: 3, fact: fact)) }
        let date = Self.dateText(now)
        candidates.append(Candidate(priority: 1, weight: 1, fact: date))

        // An album's anniversary beats everything else for the day.
        let top = candidates.map(\.priority).max() ?? 1
        if top == 5 { candidates = candidates.filter { $0.priority == 5 } }
        // Stable sort: best first, same priority keeps its order.
        let ordered = candidates.enumerated()
            .sorted { $0.element.priority != $1.element.priority ? $0.element.priority > $1.element.priority : $0.offset < $1.offset }
            .map(\.element)

        // Same (day, hour) always picks the same line; another hour may pick another.
        let seed = ((parts.year ?? 0) &* 10_000 &+ (parts.month ?? 0) &* 100 &+ (parts.day ?? 0)) &* 24 &+ hour
        let newSlot = seed
        if newSlot != slot { offset = 0 }
        slot = newSlot

        lines = ordered.map { Self.compose(greeting: greeting, fact: $0.fact) }
        base = Self.weightedIndex(ordered.map(\.weight), seed: seed)
        dateLine = date
        publish()
    }

    /// Tap on the subtitle: the next thing that can be said.
    func next() {
        guard lines.count > 1 else { return }
        offset += 1
        publish()
    }

    // MARK: - Choosing

    private struct Candidate {
        let priority: Int
        let weight: Int
        let fact: String
    }

    private func publish() {
        guard !lines.isEmpty else { return }
        let text = lines[(base + offset) % lines.count]
        if text != line { line = text }
    }

    /// Deterministic weighted pick (splitmix-style mixing of the seed, no random numbers).
    private static func weightedIndex(_ weights: [Int], seed: Int) -> Int {
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        var x = UInt64(bitPattern: Int64(seed)) &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        var r = Int(x % UInt64(total))
        for (index, weight) in weights.enumerated() {
            if r < weight { return index }
            r -= weight
        }
        return 0
    }

    // MARK: - Text

    /// The greeting and the fact share the line (the Home shows up to two lines).
    private static let fitsWithGreeting = 70
    private static let titleLength = 40

    private static func greeting(hour: Int) -> String {
        switch hour {
        case 5..<12: return "Buongiorno"
        case 12..<18: return "Buon pomeriggio"
        case 18..<23: return "Buonasera"
        default: return "Buonanotte"
        }
    }

    /// "Greeting · fact" when it fits in `fitsWithGreeting` characters, otherwise the fact alone.
    private static func compose(greeting: String, fact: String) -> String {
        let joined = "\(greeting) · \(fact)"
        if !fact.contains("·"), joined.count <= fitsWithGreeting { return joined }
        return fact.prefix(1).uppercased() + fact.dropFirst()
    }

    private static func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private static func clipped(_ text: String, to length: Int) -> String {
        text.count <= length ? text : text.prefix(max(length - 1, 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Candidates

    /// Albums released on today's day and month, in the device's time zone.
    private func anniversaries(_ albums: [AlbumItem], now: Date, calendar: Calendar) -> [String] {
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        var found: [(years: Int, name: String)] = []
        for album in albums {
            guard let released = album.premiereDateValue else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: released)
            guard parts.month == today.month, parts.day == today.day,
                  let year = parts.year, let current = today.year, current > year else { continue }
            found.append((current - year, album.Name))
        }
        // The oldest first, at most three, so the line stays rare and special.
        return found.sorted { $0.years > $1.years }.prefix(3).map { item in
            let tail = item.years == 1 ? " compie 1 anno oggi" : " compie \(item.years) anni oggi"
            return "«\(Self.clipped(item.name, to: Self.titleLength))»\(tail)"
        }
    }

    /// Albums added in the last week that no recent song comes from.
    private func newMusic(_ viewModel: JellyfinViewModel, now: Date) -> String? {
        let played = Set(viewModel.recentlyPlayedTracks.compactMap(\.AlbumId))
        let fresh = viewModel.recentlyAddedAlbums.filter { album in
            guard let added = album.dateAddedDate else { return false }
            return now.timeIntervalSince(added) < 7 * 86_400 && !played.contains(album.Id)
        }
        switch fresh.count {
        case 0: return nil
        case 1: return "Nuovo: «\(Self.clipped(fresh[0].Name, to: Self.titleLength))»"
        default: return "\(fresh.count) album nuovi da ascoltare"
        }
    }

    /// From what the statistics already hold: loading them is the Home's business.
    private func stats() -> [String] {
        let store = ScrobbleStatsStore.shared
        var result: [String] = []
        if let top = store.summary(for: .week)?.topArtists.first, top.count >= 3 {
            let plays = "· \(top.count) ascolti"
            result.append("Questa settimana: \(Self.clipped(top.name, to: Self.titleLength)) \(plays)")
        }
        if store.streakDays >= 2 {
            result.append("\(store.streakDays) giorni di fila con la musica")
        }
        if store.todayCount >= 3 {
            result.append("Oggi già \(store.todayCount) ascolti")
        }
        return result
    }

    private func mixes(hour: Int, weekday: Int) -> [String] {
        let kinds = Set(MixStore.shared.mixes.map(\.kind))
        var result: [String] = []
        if kinds.contains(.daily), (5..<12).contains(hour) {
            result.append("Il Mix del giorno è pronto")
        }
        // Calendar weekday: 1 = Sunday … 7 = Saturday.
        let weekdayEvening = (2...6).contains(weekday) && (17..<21).contains(hour)
        let saturdayMorning = weekday == 7 && (6..<13).contains(hour)
        if kinds.contains(.gym), weekdayEvening || saturdayMorning {
            result.append("Mix Palestra pronto")
        }
        return result
    }

    private func mood(hour: Int, weekday: Int) -> [String] {
        var result: [String] = []
        if hour >= 22 || hour < 5 { result.append("qualcosa di tranquillo?") }
        if weekday == 6, hour >= 17 { result.append("è venerdì: alza il volume") }
        return result
    }

    /// The same artist fills most of the latest plays.
    private func repeatedArtist(_ viewModel: JellyfinViewModel) -> String? {
        let latest = viewModel.recentlyPlayedTracks.prefix(6)
        guard latest.count >= 4, let first = latest.first,
              let artist = viewModel.artistName(for: first), !artist.isEmpty else { return nil }
        let same = latest.filter { viewModel.artistName(for: $0) == artist }.count
        guard same >= 3 else { return nil }
        return "Ancora \(Self.clipped(artist, to: Self.titleLength))?"
    }
}

#if os(iOS)
/// Puts the Home's toolbar on a view, with the date as subtitle for the "Data" style (none
/// for "Messaggio per te", whose line is the first row of AppleHomeView), and keeps the
/// greeting fresh: when the Home appears, every hour, and when its inputs change.
private struct HomeToolbarModifier: ViewModifier {
    @ObservedObject var viewModel: JellyfinViewModel
    @ObservedObject private var greeting = HomeGreeting.shared
    @ObservedObject private var stats = ScrobbleStatsStore.shared
    @ObservedObject private var mixStore = MixStore.shared
    @AppStorage(HomeSubtitleStyle.storageKey) private var style = HomeSubtitleStyle.message.rawValue

    private var inputs: String {
        "\(viewModel.albums.count)|\(viewModel.recentlyPlayedTracks.first?.Id ?? "")|\(viewModel.recentlyAddedAlbums.first?.Id ?? "")|\(stats.todayCount)|\(mixStore.mixes.count)"
    }

    func body(content: Content) -> some View {
        content
            .iOSToolbar(viewModel: viewModel, title: "Home",
                        subtitle: style == HomeSubtitleStyle.date.rawValue ? greeting.dateLine : nil)
            .task(id: inputs) { greeting.refresh(viewModel: viewModel) }
            // Wakes at every full hour; leaving the Home cancels the sleep.
            .task {
                while !Task.isCancelled {
                    greeting.refresh(viewModel: viewModel)
                    let calendar = Calendar.current
                    guard let nextHour = calendar.nextDate(after: Date(), matching: DateComponents(minute: 0, second: 0),
                                                           matchingPolicy: .nextTime) else { return }
                    try? await Task.sleep(for: .seconds(max(nextHour.timeIntervalSinceNow, 1) + 1))
                }
            }
    }
}

extension View {
    func homeToolbar(viewModel: JellyfinViewModel) -> some View {
        modifier(HomeToolbarModifier(viewModel: viewModel))
    }
}
#endif
