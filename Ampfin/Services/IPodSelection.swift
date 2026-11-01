// IPodSelection.swift
// What the user marked to put on the iPod: artists, albums and playlists, kept in
// UserDefaults. The sync (IPodSync) turns it into songs.

#if os(macOS)
import Foundation

struct IPodSelectionEntry: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case artist, album, playlist

        var label: String {
            switch self {
            case .artist: return "Artista"
            case .album: return "Album"
            case .playlist: return "Playlist"
            }
        }

        var systemImage: String {
            switch self {
            case .artist: return "music.mic"
            case .album: return "square.stack"
            case .playlist: return "music.note.list"
            }
        }
    }

    let kind: Kind
    /// Jellyfin id. For an artist it is the id of the merged entry, which can change when the
    /// merge rules do: the sync looks the artist up by `name` when the id is gone.
    let itemId: String
    let name: String

    var id: String { "\(kind.rawValue):\(itemId)" }
}

/// Sources that are worked out again at every sync, switched on in the iPod page.
enum IPodDynamicSource: String, CaseIterable, Identifiable {
    case favorites, recentAlbums, recentPlayed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favorites: return "Preferiti"
        case .recentAlbums: return "Aggiunti di recente"
        case .recentPlayed: return "Ascoltati di recente"
        }
    }

    var detail: String {
        switch self {
        case .favorites: return "Brani e album con il cuore"
        case .recentAlbums: return "Gli ultimi album entrati in libreria"
        case .recentPlayed: return "Gli ultimi brani che hai ascoltato"
        }
    }

    var systemImage: String {
        switch self {
        case .favorites: return "heart"
        case .recentAlbums: return "clock"
        case .recentPlayed: return "play.circle"
        }
    }

    /// Choices for "how many", nil when the source has no number.
    var countChoices: [Int]? {
        switch self {
        case .favorites: return nil
        case .recentAlbums: return [10, 25, 50]
        case .recentPlayed: return [50, 100, 200]
        }
    }

    var defaultCount: Int {
        switch self {
        case .favorites: return 0
        case .recentAlbums: return 25
        case .recentPlayed: return 100
        }
    }

    /// Key in `IPodEntryStats` dictionaries, apart from the manual entries' ids.
    var statsKey: String { "auto:\(rawValue)" }

    /// Playlist written to /Playlists for the source.
    var playlistName: String { "Ampfin - \(title)" }
}

@MainActor
final class IPodSelection: ObservableObject {
    static let shared = IPodSelection()
    static let storageKey = "ipodSelection"

    @Published private(set) var entries: [IPodSelectionEntry]

    // The dynamic sources: a switch each, and how many for the two "recent" ones.
    @Published var favoritesOn: Bool { didSet { UserDefaults.standard.set(favoritesOn, forKey: "ipodAuto_favorites") } }
    @Published var recentAlbumsOn: Bool { didSet { UserDefaults.standard.set(recentAlbumsOn, forKey: "ipodAuto_recentAlbums") } }
    @Published var recentPlayedOn: Bool { didSet { UserDefaults.standard.set(recentPlayedOn, forKey: "ipodAuto_recentPlayed") } }
    @Published var recentAlbumsCount: Int { didSet { UserDefaults.standard.set(recentAlbumsCount, forKey: "ipodAuto_recentAlbumsCount") } }
    @Published var recentPlayedCount: Int { didSet { UserDefaults.standard.set(recentPlayedCount, forKey: "ipodAuto_recentPlayedCount") } }

    func isOn(_ source: IPodDynamicSource) -> Bool {
        switch source {
        case .favorites: return favoritesOn
        case .recentAlbums: return recentAlbumsOn
        case .recentPlayed: return recentPlayedOn
        }
    }

    func setOn(_ source: IPodDynamicSource, _ on: Bool) {
        switch source {
        case .favorites: favoritesOn = on
        case .recentAlbums: recentAlbumsOn = on
        case .recentPlayed: recentPlayedOn = on
        }
    }

    func count(_ source: IPodDynamicSource) -> Int {
        switch source {
        case .favorites: return 0
        case .recentAlbums: return recentAlbumsCount
        case .recentPlayed: return recentPlayedCount
        }
    }

    func setCount(_ source: IPodDynamicSource, _ count: Int) {
        switch source {
        case .favorites: break
        case .recentAlbums: recentAlbumsCount = count
        case .recentPlayed: recentPlayedCount = count
        }
    }

    var enabledSources: [IPodDynamicSource] { IPodDynamicSource.allCases.filter(isOn) }

    /// Changes whenever a dynamic setting does, for `.task(id:)`.
    var dynamicKey: String {
        enabledSources.map { "\($0.rawValue)\(count($0))" }.joined(separator: ",")
    }

    private init() {
        let defaults = UserDefaults.standard
        favoritesOn = defaults.bool(forKey: "ipodAuto_favorites")
        recentAlbumsOn = defaults.bool(forKey: "ipodAuto_recentAlbums")
        recentPlayedOn = defaults.bool(forKey: "ipodAuto_recentPlayed")
        recentAlbumsCount = defaults.object(forKey: "ipodAuto_recentAlbumsCount") as? Int ?? IPodDynamicSource.recentAlbums.defaultCount
        recentPlayedCount = defaults.object(forKey: "ipodAuto_recentPlayedCount") as? Int ?? IPodDynamicSource.recentPlayed.defaultCount

        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([IPodSelectionEntry].self, from: data) {
            entries = saved
        } else {
            entries = []
        }
    }

    func contains(_ kind: IPodSelectionEntry.Kind, id: String) -> Bool {
        entries.contains { $0.kind == kind && $0.itemId == id }
    }

    func add(_ kind: IPodSelectionEntry.Kind, id: String, name: String) {
        guard !contains(kind, id: id) else { return }
        entries.append(IPodSelectionEntry(kind: kind, itemId: id, name: name))
        save()
    }

    func remove(_ entry: IPodSelectionEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func remove(_ kind: IPodSelectionEntry.Kind, id: String) {
        entries.removeAll { $0.kind == kind && $0.itemId == id }
        save()
    }

    func toggle(_ kind: IPodSelectionEntry.Kind, id: String, name: String) {
        if contains(kind, id: id) { remove(kind, id: id) } else { add(kind, id: id, name: name) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
#endif
