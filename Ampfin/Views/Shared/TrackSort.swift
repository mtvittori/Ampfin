// TrackSort.swift
// The orders of a song list (Brani, Preferiti) and the month headers of "Aggiunti di recente".

import SwiftUI

enum TrackSort: String, CaseIterable, Identifiable {
    case name, artist, added
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return "Nome"
        case .artist: return "Artista"
        case .added: return "Aggiunti di recente"
        }
    }

    /// The songs in this order. `artists` maps a song id to the artist shown for it.
    /// Stable: songs that tie keep the order they came in.
    func sorted(_ tracks: [AudioItem], artists: [String: String]) -> [AudioItem] {
        switch self {
        case .name:
            return tracks.sorted { $0.Name.localizedStandardCompare($1.Name) == .orderedAscending }
        case .artist:
            // Artist, then album, then the library's own order (no track numbers here).
            return tracks.enumerated().sorted { a, b in
                let byArtist = (artists[a.element.Id] ?? "").localizedStandardCompare(artists[b.element.Id] ?? "")
                if byArtist != .orderedSame { return byArtist == .orderedAscending }
                let byAlbum = (a.element.Album ?? "").localizedStandardCompare(b.element.Album ?? "")
                if byAlbum != .orderedSame { return byAlbum == .orderedAscending }
                return a.offset < b.offset
            }.map(\.element)
        case .added:
            // Newest first; songs without a date (old cache) go last, in their order.
            return tracks.sortedNewestFirst(by: \.dateAddedDate)
        }
    }

    /// Month headers for songs already in "added" order ("Ottobre 2026"); a song with no
    /// date lands in "Senza data" at the end.
    static func monthSections(_ tracks: [AudioItem]) -> [LetterSection<AudioItem>] {
        var sections: [LetterSection<AudioItem>] = []
        var current: (label: String, items: [AudioItem])?
        // Songs come newest first, so most of them fall in the month already open: a date
        // inside its interval skips the calendar (8.000 component lookups were ~50 ms).
        var openMonth: DateInterval?
        let calendar = Calendar.current

        for track in tracks {
            let date = track.dateAddedDate
            // DateInterval.contains counts its end, which is already the next month.
            let sameMonth = date.map { day in openMonth.map { day >= $0.start && day < $0.end } ?? false } ?? false
            // A song with no date starts "Senza data" once, then joins it.
            let sameUndated = date == nil && current?.label == "Senza data"
            if current == nil || !(sameMonth || sameUndated) {
                if let current { sections.append(LetterSection(letter: current.label, items: current.items)) }
                current = (date.map(monthLabel) ?? "Senza data", [])
                openMonth = date.flatMap { calendar.dateInterval(of: .month, for: $0) }
            }
            current?.items.append(track)
        }
        if let current { sections.append(LetterSection(letter: current.label, items: current.items)) }
        return sections
    }

    private static func monthLabel(_ date: Date) -> String {
        monthFormatter.string(from: date).capitalized
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.setLocalizedDateFormatFromTemplate("LLLL yyyy")
        return formatter
    }()
}

extension JellyfinViewModel {
    /// Song id to artist name, built once for a sort instead of at every comparison.
    func artistNames(for tracks: [AudioItem]) -> [String: String] {
        Dictionary(tracks.map { ($0.Id, artistName(for: $0) ?? "") }, uniquingKeysWith: { first, _ in first })
    }
}
