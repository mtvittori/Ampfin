// PlaylistItem.swift
import Foundation

// Modello per una playlist (coerente con gli altri modelli che usano "Id" + computed "id")
struct PlaylistItem: Codable, Identifiable, Hashable {
    let Id: String
    var id: String { Id }
    let Name: String
    let ItemCount: Int? // numero di brani nella playlist (se fornito dall'API)
    let OwnerId: String?
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
