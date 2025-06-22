import Foundation

// Definiamo prima le struct di supporto usate da AudioItem
struct ArtistInfo: Codable {
    let Name: String
    let Id: String
}

struct MediaSourceInfo: Codable {
    let Container: String?
}

struct AudioItem: Codable, Identifiable {
    let Id: String
    var id: String { Id }
    
    let Name: String
    let Artists: [String]?
    let AlbumArtists: [ArtistInfo]?
    let Album: String?
    let RunTimeTicks: Int64?
    let AlbumId: String?
    let Genres: [String]?
    let MediaSources: [MediaSourceInfo]?
    
    var mainArtistName: String? { AlbumArtists?.first?.Name ?? Artists?.first }
    
    var duration: TimeInterval? {
        guard let ticks = RunTimeTicks else { return nil }
        return TimeInterval(ticks) / 10_000_000.0
    }
    
    var isLossless: Bool {
        guard let container = MediaSources?.first?.Container?.lowercased() else { return false }
        return container == "flac" || container == "alac"
    }
}
