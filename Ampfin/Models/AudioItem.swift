import Foundation

// Definiamo prima le struct di supporto usate da AudioItem
struct ArtistInfo: Codable {
    let Name: String
    let Id: String
}

struct MediaStreamInfo: Codable {
    let BitRate: Int?
    let SampleRate: Int?
    let Channels: Int?
    let Codec: String?
    let BitDepth: Int?
}

struct MediaSourceInfo: Codable {
    let Container: String?
    let Bitrate: Int?
    let MediaStreams: [MediaStreamInfo]?
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
    /// The user's plays and favorite flag, when the server sends them (per user).
    let UserData: UserItemData?
    /// The song's entry inside a playlist, needed to take it out of the playlist.
    let PlaylistItemId: String?
    
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

/// What Jellyfin keeps for each user about an item: how often and when it was played.
struct UserItemData: Codable, Hashable {
    let PlayCount: Int?
    let LastPlayedDate: String?
    let IsFavorite: Bool?
    let Played: Bool?

    /// LastPlayedDate as a date. Jellyfin writes seven decimals ("…:12.1234567Z"), which
    /// ISO8601DateFormatter doesn't read, so the seconds are cut first.
    var lastPlayed: Date? {
        guard let raw = LastPlayedDate, raw.count >= 19 else { return nil }
        return Self.parser.date(from: String(raw.prefix(19)) + "Z")
    }

    private static let parser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
