import Foundation

/// Codec, sample rate and bit depth of single songs. The library lists don't carry them
/// (every embedded cover and lyric is a stream of its own: ~25 MB of JSON for 8.800 songs),
/// so they are fetched for the song that plays, and kept here for a while.
final class MediaInfoCache {
    static let shared = MediaInfoCache()

    private final class Box {
        let sources: [MediaSourceInfo]
        init(_ sources: [MediaSourceInfo]) { self.sources = sources }
    }

    // NSCache is thread-safe, and drops entries by itself under memory pressure.
    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 500
        return cache
    }()

    func sources(for itemId: String) -> [MediaSourceInfo]? {
        cache.object(forKey: itemId as NSString)?.sources
    }

    func store(_ sources: [MediaSourceInfo], for itemId: String) {
        cache.setObject(Box(sources), forKey: itemId as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
