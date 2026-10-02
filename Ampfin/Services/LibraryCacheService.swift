import Foundation

/// Metadata stored alongside the cached library data.
struct LibraryCacheMetadata: Codable {
    let lastSyncDate: Date
    let genres: [String]
}

/// Persistent disk cache for the Jellyfin music library (tracks, albums, artists).
/// Stores JSON files in `Library/Caches/LibraryCache/` so the system can purge them under storage pressure.
final class LibraryCacheService {
    static let shared = LibraryCacheService()

    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let ioQueue = DispatchQueue(label: "com.ampfin.librarycache", qos: .utility)

    private enum FileName {
        static let tracks = "tracks.json"
        static let albums = "albums.json"
        static let artists = "artists.json"
        static let metadata = "cache_meta.json"
    }

    private init() {
        let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectory = cacheDir.appendingPathComponent("LibraryCache")
        if !fileManager.fileExists(atPath: self.cacheDirectory.path) {
            try? fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Save

    func saveLibrary(
        tracks: [AudioItem],
        albums: [AlbumItem],
        artists: [ArtistItem],
        genres: [String]
    ) {
        let encoder = JSONEncoder()
        let meta = LibraryCacheMetadata(lastSyncDate: Date(), genres: genres)

        ioQueue.async { [cacheDirectory] in
            if let data = try? encoder.encode(tracks) {
                try? data.write(to: cacheDirectory.appendingPathComponent(FileName.tracks))
            }
            if let data = try? encoder.encode(albums) {
                try? data.write(to: cacheDirectory.appendingPathComponent(FileName.albums))
            }
            if let data = try? encoder.encode(artists) {
                try? data.write(to: cacheDirectory.appendingPathComponent(FileName.artists))
            }
            if let data = try? encoder.encode(meta) {
                try? data.write(to: cacheDirectory.appendingPathComponent(FileName.metadata))
            }
        }
    }

    // MARK: - Load

    struct CachedLibrary {
        let tracks: [AudioItem]
        let albums: [AlbumItem]
        let artists: [ArtistItem]
        let genres: [String]
        let lastSyncDate: Date
    }

    /// Loads the cached library from disk. Returns nil if cache is empty or corrupt.
    func loadLibrary() async -> CachedLibrary? {
        await withCheckedContinuation { continuation in
            ioQueue.async { [cacheDirectory] in
                let decoder = JSONDecoder()

                guard
                    let tracksData = try? Data(contentsOf: cacheDirectory.appendingPathComponent(FileName.tracks)),
                    let albumsData = try? Data(contentsOf: cacheDirectory.appendingPathComponent(FileName.albums)),
                    let artistsData = try? Data(contentsOf: cacheDirectory.appendingPathComponent(FileName.artists)),
                    let metaData = try? Data(contentsOf: cacheDirectory.appendingPathComponent(FileName.metadata)),
                    let tracks = try? decoder.decode([AudioItem].self, from: tracksData),
                    let albums = try? decoder.decode([AlbumItem].self, from: albumsData),
                    let artists = try? decoder.decode([ArtistItem].self, from: artistsData),
                    let meta = try? decoder.decode(LibraryCacheMetadata.self, from: metaData)
                else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: CachedLibrary(
                    tracks: tracks,
                    albums: albums,
                    artists: artists,
                    genres: meta.genres,
                    lastSyncDate: meta.lastSyncDate
                ))
            }
        }
    }

    // MARK: - Metadata only (lightweight, for displaying last sync date)

    func loadMetadata() -> LibraryCacheMetadata? {
        let url = cacheDirectory.appendingPathComponent(FileName.metadata)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LibraryCacheMetadata.self, from: data)
    }

    // MARK: - Clear

    func clearAll() {
        ioQueue.async { [cacheDirectory, fileManager] in
            try? fileManager.removeItem(at: cacheDirectory)
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Disk size

    func diskSize() -> Int64 {
        guard let files = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        return files.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }
}
