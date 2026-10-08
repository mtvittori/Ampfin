// PlaylistItem.swift
import Foundation

// Modello per una playlist (coerente con gli altri modelli che usano "Id" + computed "id")
struct PlaylistItem: Codable, Identifiable, Hashable {
    let Id: String
    var id: String { Id }
    let Name: String
    let ItemCount: Int? // numero di brani nella playlist (se fornito dall'API)
    let ChildCount: Int?
    let OwnerId: String?
    let Path: String?
    let DateCreated: String?

    var songCount: Int? { ChildCount ?? ItemCount }

    /// A playlist Jellyfin made from an .m3u/.pls file found in an album folder: it's
    /// just the album again, so it stays out of the list.
    var isAlbumFile: Bool {
        guard let path = Path?.lowercased() else { return false }
        return path.hasSuffix(".m3u") || path.hasSuffix(".m3u8") || path.hasSuffix(".pls")
    }

    /// Made by a server plugin: AudioMuse-AI ("…_automatic") or Playlist Generator.
    var isServerMix: Bool {
        Name.hasSuffix("_automatic") || Name == "My Personal Mix"
    }
    // Aggiungi altri campi se necessario (Description, DateCreated, ecc.)

    // Hashable / Equatable basati su Id
    func hash(into hasher: inout Hasher) {
        hasher.combine(Id)
    }
    static func == (lhs: PlaylistItem, rhs: PlaylistItem) -> Bool {
        lhs.Id == rhs.Id
    }
}

// Contenitore per la risposta dell'API che ritorna playlist
struct PlaylistResponse: Codable {
    let Items: [PlaylistItem]
}
