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
            // Newest first; songs without a date (old cache) go last, in their order. Each
            // date is read once, not at every comparison.
            let dated = tracks.enumerated().map { (offset: $0.offset, track: $0.element,
                                                   date: $0.element.dateAddedDate ?? .distantPast) }
            return dated.sorted { a, b in
                a.date != b.date ? a.date > b.date : a.offset < b.offset
            }.map(\.track)
        }
    }

    /// Month headers for songs already in "added" order ("Ottobre 2026"); a song with no
    /// date lands in "Senza data" at the end.
    static func monthSections(_ tracks: [AudioItem]) -> [LetterSection<AudioItem>] {
        var sections: [LetterSection<AudioItem>] = []
        var current: (label: String, items: [AudioItem])?
        var lastMonth: DateComponents?
        let calendar = Calendar.current

        for track in tracks {
            let date = track.dateAddedDate
            let month = date.map { calendar.dateComponents([.year, .month], from: $0) }
            if current == nil || month != lastMonth {
                if let current { sections.append(LetterSection(letter: current.label, items: current.items)) }
                current = (date.map(monthLabel) ?? "Senza data", [])
                lastMonth = month
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
