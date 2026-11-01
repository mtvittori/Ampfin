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

@MainActor
final class IPodSelection: ObservableObject {
    static let shared = IPodSelection()
    static let storageKey = "ipodSelection"

    @Published private(set) var entries: [IPodSelectionEntry]

    private init() {
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
