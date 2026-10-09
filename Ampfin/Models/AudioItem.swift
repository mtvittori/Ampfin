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
    /// "Audio", "Video" (the embedded cover) and so on. Optional: old cached items lack it.
    let streamType: String?

    private enum CodingKeys: String, CodingKey {
        case BitRate, SampleRate, Channels, Codec, BitDepth
        case streamType = "Type"
    }
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
    /// When the song was added to the library; needs `Fields=DateCreated`. Optional: a
    /// library cache written before has none.
    let DateCreated: String?
    var dateAddedDate: Date? { DateCreated.flatMap(AlbumItem.parseDate) }

    var mainArtistName: String? { AlbumArtists?.first?.Name ?? Artists?.first }
    
    var duration: TimeInterval? {
        guard let ticks = RunTimeTicks else { return nil }
        return TimeInterval(ticks) / 10_000_000.0
    }
    
    var isLossless: Bool {
        guard let container = MediaSources?.first?.Container?.lowercased() else { return false }
        return container == "flac" || container == "alac"
    }

    /// The audio stream of the first media source (not the embedded cover, which is a "video" stream).
    var sourceAudioStream: MediaStreamInfo? {
        MediaSources?.first?.MediaStreams?.first {
            $0.streamType == "Audio" || ($0.streamType == nil && $0.SampleRate != nil)
        }
    }

    /// Sample rate of the original file, nil when the server didn't say.
    var sourceSampleRate: Int? {
        guard let rate = sourceAudioStream?.SampleRate, rate > 0 else { return nil }
        return rate
    }

    /// Hi-res: above what the iPhone's output runs at (48 kHz). Unknown counts as no.
    var isAbove48k: Bool { (sourceSampleRate ?? 0) > 48_000 }

    /// Short quality of the original file for the player: "FLAC · 24 bit · 96 kHz" for lossless,
    /// "MP3 · 320 kbps" for lossy. Parts the server didn't send are left out.
    /// `convertedTo48k` appends " → 48 kHz" when the song is being played through the conversion.
    func qualityLabel(convertedTo48k: Bool = false) -> String? {
        let stream = sourceAudioStream
        let source = MediaSources?.first
        let codecName = (stream?.Codec ?? source?.Container)?.lowercased()
        guard let codecName, !codecName.isEmpty else { return nil }

        var parts = [codecName.uppercased()]
        let lossless = ["flac", "alac", "wavpack", "ape", "wav", "aiff"].contains(codecName) || codecName.hasPrefix("pcm")
        if lossless {
            if let depth = stream?.BitDepth, depth > 0 { parts.append("\(depth) bit") }
            if let rate = sourceSampleRate { parts.append(Self.kHzText(rate)) }
        } else if let bitrate = stream?.BitRate ?? source?.Bitrate, bitrate > 0 {
            parts.append("\(Int((Double(bitrate) / 1000).rounded())) kbps")
        }
        var label = parts.joined(separator: " · ")
        if convertedTo48k && isAbove48k { label += " → 48 kHz" }
        return label
    }

    /// 44100 → "44,1 kHz", 96000 → "96 kHz" (Italian decimal comma).
    private static func kHzText(_ hz: Int) -> String {
        let kHz = Double(hz) / 1000
        if kHz == kHz.rounded() { return "\(Int(kHz)) kHz" }
        return String(format: "%.1f kHz", kHz).replacingOccurrences(of: ".", with: ",")
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
