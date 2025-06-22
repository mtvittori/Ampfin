// In Models/APIResponseModels.swift
import Foundation

// Contenitore per la risposta dei brani
struct AudioResponse: Codable {
    let Items: [AudioItem]
}

// Contenitore per la risposta degli album
struct AlbumResponse: Codable {
    let Items: [AlbumItem]
}

// Contenitore per la risposta degli artisti
struct ArtistResponse: Codable {
    let Items: [ArtistItem]
}

// Contenitore per la risposta dei generi (sebbene non usata direttamente nel fetch, è bene averla per coerenza)
struct GenreResponse: Codable {
    let Items: [GenreItem]
}
