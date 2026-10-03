// CoverSearch.swift
import Foundation

/// A cover the user can pick for an album.
struct CoverCandidate: Identifiable, Hashable {
    var id: URL { url }
    /// Full-size image, the one the server downloads.
    let url: URL
    /// Small version for the grid.
    let thumbnail: URL
    let width: Int?
    let height: Int?
    /// "iTunes", "Deezer", "TheAudioDB"…
    let source: String
    /// "Artist — Album" as the store calls it, when known.
    let title: String?

    var sizeLabel: String? {
        guard let width, let height, width > 0 else { return nil }
        return "\(width)×\(height)"
    }
}

/// Searches the music stores for covers. These are public APIs that need no key.
enum CoverSearch {
    static func search(_ term: String) async -> [CoverCandidate] {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        async let itunes = (try? iTunes(term)) ?? []
        async let deezer = (try? deezer(term)) ?? []
        return await itunes + deezer
    }

    private static func iTunes(_ term: String) async throws -> [CoverCandidate] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [URLQueryItem(name: "term", value: term),
                                 URLQueryItem(name: "entity", value: "album"),
                                 URLQueryItem(name: "limit", value: "12")]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = json?["results"] as? [[String: Any]] ?? []
        return results.compactMap { result in
            // The artwork URL carries its size: swapping it gives up to 3000 px.
            guard let small = result["artworkUrl100"] as? String,
                  let full = URL(string: small.replacingOccurrences(of: "100x100bb", with: "1500x1500bb")),
                  let thumb = URL(string: small.replacingOccurrences(of: "100x100bb", with: "300x300bb"))
            else { return nil }
            let title = [result["artistName"] as? String, result["collectionName"] as? String]
                .compactMap { $0 }.joined(separator: " — ")
            return CoverCandidate(url: full, thumbnail: thumb, width: 1500, height: 1500,
                                  source: "iTunes", title: title)
        }
    }

    private static func deezer(_ term: String) async throws -> [CoverCandidate] {
        var components = URLComponents(string: "https://api.deezer.com/search/album")!
        components.queryItems = [URLQueryItem(name: "q", value: term), URLQueryItem(name: "limit", value: "12")]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = json?["data"] as? [[String: Any]] ?? []
        return results.compactMap { result in
            guard let big = (result["cover_xl"] as? String).flatMap(URL.init(string:)) else { return nil }
            let thumb = (result["cover_medium"] as? String).flatMap(URL.init(string:)) ?? big
            let artist = (result["artist"] as? [String: Any])?["name"] as? String
            let title = [artist, result["title"] as? String].compactMap { $0 }.joined(separator: " — ")
            return CoverCandidate(url: big, thumbnail: thumb, width: 1000, height: 1000,
                                  source: "Deezer", title: title)
        }
    }
}

/// Per-item tag that goes into the cover URLs. Bumped when a cover is changed from
/// the app: the URL changes, so every cache keyed by URL (images, palettes) loads the new one.
/// Covers changed elsewhere still need "Svuota cache" on this device.
enum CoverRevisions {
    private static let key = "cover_revisions"
    private static let lock = NSLock()
    private static var tags: [String: String] = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]

    static func tag(for itemId: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return tags[itemId] ?? ""
    }

    static func bump(_ itemId: String) {
        lock.lock()
        tags[itemId] = String(Int(Date().timeIntervalSince1970))
        let snapshot = tags
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: key)
    }
}
