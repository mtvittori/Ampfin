// IPodWorker.swift
// The copying half of the iPod sync, away from the main actor: works out file names, keeps the
// manifest, downloads each original, converts or copies it, writes covers, lyrics and
// playlists. The manifest (/Musica/.ampfin-ipod.json) lists every file this app put on the
// iPod; only those are ever deleted, so the user's own music in /Musica is never touched.

#if os(macOS)
import Foundation

// MARK: - Manifest

struct IPodManifest: Codable {
    struct Item: Codable {
        /// From the volume root, e.g. "/Musica/Arctic Monkeys/2013 - AM/01 Do I Wanna Know.m4a".
        var path: String
        /// "copy" for a file put there as it is, otherwise the format it was converted to.
        var format: String
        var size: Int64
        var sourceSize: Int64
        var sourceDate: String?
    }

    var version = 1
    var items: [String: Item] = [:]
    /// Folders where this app wrote `cover.jpg`.
    var covers: [String] = []
    var playlists: [String] = []
}

/// Serializes the manifest between the two songs being copied at once.
private actor IPodManifestStore {
    private(set) var manifest: IPodManifest
    private let url: URL
    private var claimedCovers: Set<String> = []

    init(manifest: IPodManifest, url: URL) {
        self.manifest = manifest
        self.url = url
    }

    func item(_ id: String) -> IPodManifest.Item? { manifest.items[id] }
    func set(_ id: String, _ item: IPodManifest.Item) { manifest.items[id] = item }
    func remove(_ id: String) { manifest.items[id] = nil }
    func setPlaylists(_ paths: [String]) { manifest.playlists = paths }
    func hasCover(_ folder: String) -> Bool { manifest.covers.contains(folder) }
    func addCover(_ folder: String) { if !manifest.covers.contains(folder) { manifest.covers.append(folder) } }
    func removeCover(_ folder: String) { manifest.covers.removeAll { $0 == folder } }

    /// One song asks for the cover of its folder, the others don't repeat it.
    func claimCover(_ folder: String) -> Bool { claimedCovers.insert(folder).inserted }

    /// Written whole through a temporary file, so a cut cable leaves the old one intact.
    func save() throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - File names

enum IPodPaths {
    static let musicFolder = "/Musica"
    static let playlistFolder = "/Playlists"
    static let manifestPath = "/Musica/.ampfin-ipod.json"

    /// One path component that FAT32 accepts: no `\ / : * ? " < > |` or control characters,
    /// no trailing dots or spaces, at most `limit` characters, composed (NFC) like Rockbox shows it.
    static func sanitize(_ name: String, limit: Int = 100) -> String {
        let illegal = CharacterSet(charactersIn: "\\/:*?\"<>|").union(.controlCharacters)
        var cleaned = String(name.precomposedStringWithCanonicalMapping.unicodeScalars.map {
            illegal.contains($0) ? "_" : Character($0)
        })
        cleaned = trim(cleaned)
        if cleaned.count > limit { cleaned = trim(String(cleaned.prefix(limit))) }
        return cleaned.isEmpty ? "_" : cleaned
    }

    private static func trim(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = result.last, last == "." || last == " " { result.removeLast() }
        return result
    }

    /// Folder of the album: "/Musica/<Artist>/<Year - Album>".
    static func albumFolder(_ track: IPodTrack) -> String {
        let artist = sanitize(track.albumArtist)
        let album = track.album.flatMap { $0.isEmpty ? nil : $0 } ?? "Senza album"
        let folder = track.year.map { $0 > 0 ? "\($0) - \(album)" : album } ?? album
        return "\(musicFolder)/\(artist)/\(sanitize(folder))"
    }

    /// "03 Title", "02-03 Title" on a multi-disc album, just "Title" without a number.
    static func stem(_ track: IPodTrack) -> String {
        var prefix = ""
        if let number = track.trackNumber, number > 0 {
            if track.discCount > 1 {
                prefix = String(format: "%02d-%02d ", track.disc ?? 1, number)
            } else {
                prefix = String(format: "%02d ", number)
            }
        }
        return prefix + sanitize(track.title)
    }

    /// Rockbox's path limit is 260 bytes.
    static let maxPathBytes = 250

    /// Final path (without extension) for each song. Two songs that would get the same name
    /// (FAT32 ignores case) get " (2)", " (3)"… The order is fixed, so a second sync names
    /// the files the same way.
    static func plan(_ tracks: [IPodTrack], format: IPodFormat) -> [(track: IPodTrack, base: String)] {
        let sorted = tracks.sorted { a, b in
            let keyA = (albumFolder(a).lowercased(), a.disc ?? 0, a.trackNumber ?? Int.max, a.title.lowercased(), a.id)
            let keyB = (albumFolder(b).lowercased(), b.disc ?? 0, b.trackNumber ?? Int.max, b.title.lowercased(), b.id)
            return keyA < keyB
        }
        var used = Set<String>()
        return sorted.map { track in
            let folder = albumFolder(track)
            let ext = track.expectedExtension(for: format)
            var stem = stem(track)
            // A long name is cut, keeping the number in front.
            while (folder + "/" + stem + "." + ext).utf8.count > maxPathBytes, stem.count > 8 {
                stem = trim(String(stem.dropLast()))
            }
            var candidate = stem
            var n = 2
            while !used.insert((folder + "/" + candidate + "." + ext).lowercased()).inserted {
                candidate = "\(stem) (\(n))"
                n += 1
            }
            return (track, folder + "/" + candidate)
        }
    }

    /// Only paths this app writes are ever deleted or replaced.
    static func isOurs(_ path: String) -> Bool {
        (path.hasPrefix(musicFolder + "/") || path.hasPrefix(playlistFolder + "/")) && !path.contains("/../")
    }
}

// MARK: - Worker

private struct IPodFatal: Error {
    let message: String
}

final class IPodWorker: @unchecked Sendable {
    private let volume: URL
    private let format: IPodFormat
    private let tracks: [IPodTrack]
    private let playlists: [IPodPlaylistJob]
    private let api: JellyfinAPIService
    private let onProgress: @Sendable (IPodProgress) -> Void

    private let fm = FileManager.default
    private let lock = NSLock()
    private var state = IPodProgress()
    private let tempFolder: URL

    /// Free space kept out of the way of the copy, for the file system's own bookkeeping.
    private let spaceMargin: Int64 = 16 * 1024 * 1024

    init(volume: URL, format: IPodFormat, tracks: [IPodTrack], playlists: [IPodPlaylistJob],
         api: JellyfinAPIService, progress: @escaping @Sendable (IPodProgress) -> Void) {
        self.volume = volume
        self.format = format
        self.tracks = tracks
        self.playlists = playlists
        self.api = api
        self.onProgress = progress
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        tempFolder = caches.appendingPathComponent("ampfin-ipod", isDirectory: true)
    }

    private func report(_ change: (inout IPodProgress) -> Void) {
        lock.lock()
        change(&state)
        let snapshot = state
        lock.unlock()
        onProgress(snapshot)
    }

    private func url(_ path: String) -> URL {
        volume.appendingPathComponent(String(path.dropFirst()))
    }

    private func exists(_ path: String) -> Bool {
        fm.fileExists(atPath: url(path).path)
    }

    private func isConnected() -> Bool { IPodVolume.looksLikeRockbox(volume) }

    // MARK: Run

    func run() async -> IPodSummary {
        var summary = IPodSummary()
        let scoped = volume.startAccessingSecurityScopedResource()
        defer { if scoped { volume.stopAccessingSecurityScopedResource() } }
        // Leftovers of an interrupted run.
        try? fm.removeItem(at: tempFolder)
        try? fm.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempFolder) }

        guard isConnected() else {
            summary.stopReason = "L'iPod non è collegato."
            return summary
        }

        // The manifest: an unreadable one stops everything, rather than being overwritten.
        let manifestURL = url(IPodPaths.manifestPath)
        var loaded = IPodManifest()
        if fm.fileExists(atPath: manifestURL.path) {
            guard let data = try? Data(contentsOf: manifestURL), let parsed = try? JSONDecoder().decode(IPodManifest.self, from: data) else {
                summary.stopReason = "Non riesco a leggere \(IPodPaths.manifestPath) sull'iPod: non lo sovrascrivo."
                return summary
            }
            loaded = parsed
        }
        let store = IPodManifestStore(manifest: loaded, url: manifestURL)
        do {
            try fm.createDirectory(at: url(IPodPaths.musicFolder), withIntermediateDirectories: true)
        } catch {
            summary.stopReason = "Non riesco a scrivere sull'iPod: \(error.localizedDescription)"
            return summary
        }

        // What has to happen.
        let planned = IPodPaths.plan(tracks, format: format)
        let wanted = Set(planned.map(\.track.id))
        let removals = loaded.items.filter { !wanted.contains($0.key) }
        var additions: [(track: IPodTrack, base: String)] = []
        var moves: [(track: IPodTrack, base: String, old: IPodManifest.Item)] = []
        var unchanged = 0
        for entry in planned {
            guard let old = loaded.items[entry.track.id], exists(old.path), IPodPaths.isOurs(old.path) else {
                additions.append(entry)
                continue
            }
            if needsRedo(old.format, entry.track) {
                additions.append(entry)
                continue
            }
            let wantedPath = entry.base + "." + (old.path as NSString).pathExtension
            if wantedPath.lowercased() != old.path.lowercased() {
                moves.append((entry.track, entry.base, old))
            } else {
                unchanged += 1
            }
        }
        summary.skipped = unchanged

        // Does it fit? Space freed by what leaves counts.
        let needed = additions.reduce(Int64(0)) { $0 + $1.track.estimatedBytes(for: format) }
        let reclaimed = removals.values.reduce(Int64(0)) { $0 + $1.size }
            + additions.reduce(Int64(0)) { $0 + (loaded.items[$1.track.id]?.size ?? 0) }
        if let free = IPodVolume.space(of: volume)?.free, needed - reclaimed + spaceMargin > free {
            summary.stopReason = "Non c'è abbastanza spazio sull'iPod: servono circa \(Self.size(needed - reclaimed)) e ne restano \(Self.size(free)). Togli qualcosa dalla selezione."
            return summary
        }

        // 1. Songs no longer selected.
        report { $0 = IPodProgress(phase: .removing, done: 0, total: removals.count) }
        var touchedFolders = Set<String>()
        for (index, entry) in removals.enumerated() {
            if Task.isCancelled { break }
            if IPodPaths.isOurs(entry.value.path) {
                remove(path: entry.value.path)
                touchedFolders.insert((entry.value.path as NSString).deletingLastPathComponent)
            }
            await store.remove(entry.key)
            summary.removed += 1
            report { $0.done = index + 1 }
            if index % 25 == 24 { try? await store.save() }
        }
        // 2. Files whose name changed (the album was renamed, the artists merged…).
        for entry in moves {
            if Task.isCancelled { break }
            do {
                let newPath = entry.base + "." + (entry.old.path as NSString).pathExtension
                try fm.createDirectory(at: url((newPath as NSString).deletingLastPathComponent), withIntermediateDirectories: true)
                try fm.moveItem(at: url(entry.old.path), to: url(newPath))
                let oldLyrics = Self.lyricsPath(for: entry.old.path)
                if exists(oldLyrics) { try? fm.moveItem(at: url(oldLyrics), to: url(Self.lyricsPath(for: newPath))) }
                var item = entry.old
                item.path = newPath
                await store.set(entry.track.id, item)
                touchedFolders.insert((entry.old.path as NSString).deletingLastPathComponent)
                await ensureCover(for: entry.track, store: store)
            } catch {
                summary.errors.append("\(entry.track.title): non riesco a rinominarlo (\(error.localizedDescription))")
            }
        }
        try? await store.save()
        await pruneFolders(touchedFolders, store: store)

        // 3. Songs to add, two at a time.
        report { $0 = IPodProgress(phase: .copying, done: 0, total: additions.count) }
        var stop: String?
        await withTaskGroup(of: (IPodTrack, AddOutcome).self) { group in
            var next = additions.makeIterator()
            func spawn() -> Bool {
                guard let entry = next.next() else { return false }
                group.addTask { (entry.track, await self.add(entry.track, base: entry.base, store: store)) }
                return true
            }
            for _ in 0..<2 { _ = spawn() }
            while let (track, outcome) = await group.next() {
                switch outcome {
                case .added(let bytes, let note):
                    summary.added += 1
                    if let note { summary.errors.append("\(track.title): \(note)") }
                    report { $0.done += 1; $0.bytes += bytes }
                case .skipped(let reason):
                    summary.skipped += 1
                    summary.errors.append("\(track.title): \(reason)")
                    report { $0.done += 1 }
                case .failed(let reason):
                    summary.errors.append("\(track.title): \(reason)")
                    report { $0.done += 1 }
                case .fatal(let reason):
                    stop = stop ?? reason
                    group.cancelAll()
                case .cancelled:
                    break
                }
                if stop == nil, !Task.isCancelled { _ = spawn() }
            }
        }
        try? await store.save()
        if let stop { summary.stopReason = stop }
        if summary.stopReason == nil, Task.isCancelled { summary.stopReason = "Sincronizzazione annullata." }
        if summary.stopReason != nil { return summary }

        // 4. Playlists.
        report { $0 = IPodProgress(phase: .playlists, done: 0, total: playlists.count) }
        await writePlaylists(store: store, summary: &summary)
        try? await store.save()
        return summary
    }

    /// Whether a file already on the iPod was made in another format than the one wanted now.
    private func needsRedo(_ oldFormat: String, _ track: IPodTrack) -> Bool {
        if format.bitrate == nil { return oldFormat != "copy" }
        if track.isConvertibleLossless { return oldFormat != format.rawValue }
        // An .m4a may have been converted (it was ALAC) or not (it was AAC): only the first
        // kind depends on the bitrate.
        if track.isAmbiguousM4A { return oldFormat != "copy" && oldFormat != format.rawValue }
        return oldFormat != "copy"
    }

    // MARK: Adding

    private enum AddOutcome {
        case added(bytes: Int64, note: String?)
        case skipped(String)
        case failed(String)
        case fatal(String)
        case cancelled
    }

    private func add(_ track: IPodTrack, base: String, store: IPodManifestStore) async -> AddOutcome {
        if Task.isCancelled { return .cancelled }
        report { $0.currentTitle = track.title }
        var cleanup: [URL] = []
        defer { for file in cleanup { try? fm.removeItem(at: file) } }

        do {
            // The original, into the Mac's caches; it is deleted as soon as this song is done.
            let (original, sourceSize, downloadedExtension) = try await download(track)
            cleanup.append(original)

            var file = original
            var ext = downloadedExtension
            var effectiveFormat = "copy"
            var note: String?
            if let bitrate = format.bitrate, track.isConvertibleLossless || track.isAmbiguousM4A,
               await IPodConverter.isLossless(url: original, containerHint: track.container) {
                let converted = tempFolder.appendingPathComponent("\(UUID().uuidString).m4a")
                cleanup.append(converted)
                do {
                    try await IPodConverter.convertToAAC(source: original, destination: converted, bitrate: bitrate, tags: Self.tags(for: track))
                    file = converted
                    ext = "m4a"
                    effectiveFormat = format.rawValue
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    // Better the original than nothing; the next sync tries again.
                    note = "copiato senza conversione (\(error.localizedDescription))"
                }
            }
            if Task.isCancelled { return .cancelled }

            let path = base + "." + ext
            guard IPodPaths.isOurs(path) else { return .failed("nome non valido") }
            let old = await store.item(track.id)
            // A file that isn't in the manifest is the user's: left alone.
            if exists(path), old?.path.lowercased() != path.lowercased() {
                return .skipped("c'è già un file con lo stesso nome sull'iPod, non lo tocco")
            }

            let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? sourceSize
            if let free = IPodVolume.space(of: volume)?.free, free < size + spaceMargin {
                throw IPodFatal(message: "Spazio esaurito sull'iPod: la sincronizzazione si è fermata. Togli qualcosa dalla selezione.")
            }

            // Written under a temporary name and renamed, so a cut cable never leaves half a song.
            try fm.createDirectory(at: url((path as NSString).deletingLastPathComponent), withIntermediateDirectories: true)
            let destination = url(path)
            let part = destination.appendingPathExtension("ampfin-part")
            try? fm.removeItem(at: part)
            do {
                try fm.copyItem(at: file, to: part)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: part, to: destination)
            } catch {
                try? fm.removeItem(at: part)
                throw error
            }
            // The old file of a format change, when it has another name.
            if let old, old.path.lowercased() != path.lowercased(), IPodPaths.isOurs(old.path) {
                remove(path: old.path)
            }

            await writeLyrics(for: track, path: path)
            await ensureCover(for: track, store: store)

            await store.set(track.id, IPodManifest.Item(
                path: path, format: effectiveFormat, size: size, sourceSize: sourceSize, sourceDate: track.dateCreated))
            try await store.save()
            return .added(bytes: size, note: note)
        } catch is CancellationError {
            return .cancelled
        } catch let fatal as IPodFatal {
            return .fatal(fatal.message)
        } catch {
            if Task.isCancelled { return .cancelled }
            if !isConnected() { return .fatal("L'iPod è stato scollegato durante la copia. Ricollegalo e sincronizza di nuovo: riparte da dove era arrivato.") }
            return .failed(error.localizedDescription)
        }
    }

    private func download(_ track: IPodTrack) async throws -> (file: URL, size: Int64, ext: String) {
        guard let request = api.originalFileRequest(for: track.id) else { throw APIError.invalidURL }
        let (downloaded, response) = try await JellyfinAPIService.urlSession.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            try? fm.removeItem(at: downloaded)
            throw APIError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let ext = track.originalExtension ?? Self.extensionFor(mime: response.mimeType) ?? "audio"
        // Decoders look at the extension, which the temporary download doesn't have.
        let file = tempFolder.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try fm.moveItem(at: downloaded, to: file)
        let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        return (file, size, ext)
    }

    private static func extensionFor(mime: String?) -> String? {
        switch mime?.lowercased() {
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/aac": return "m4a"
        case "audio/ogg", "application/ogg": return "ogg"
        case "audio/opus": return "opus"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/aiff", "audio/x-aiff": return "aiff"
        default: return nil
        }
    }

    private static func tags(for track: IPodTrack) -> IPodTags {
        IPodTags(title: track.title, artist: track.artist, album: track.album, albumArtist: track.albumArtist,
                 genre: track.genre, year: track.year, trackNumber: track.trackNumber, trackTotal: track.trackTotal,
                 disc: track.disc, discTotal: track.discCount > 1 ? track.discCount : nil)
    }

    // MARK: Lyrics and covers

    static func lyricsPath(for songPath: String) -> String {
        (songPath as NSString).deletingPathExtension + ".lrc"
    }

    /// A `.lrc` next to the song when the server has timed lyrics; nothing otherwise.
    private func writeLyrics(for track: IPodTrack, path: String) async {
        guard let lines = try? await api.fetchLyrics(itemId: track.id), lines.contains(where: { $0.start != nil }) else { return }
        let text = lines.compactMap { line -> String? in
            guard let start = line.start else { return nil }
            let centis = Int((max(start, 0) * 100).rounded())
            return String(format: "[%02d:%02d.%02d]", centis / 6000, centis / 100 % 60, centis % 100) + line.text
        }.joined(separator: "\n") + "\n"
        try? text.write(to: url(Self.lyricsPath(for: path)), atomically: true, encoding: .utf8)
    }

    /// `cover.jpg` in the album's folder: a small baseline JPEG, once per folder.
    private func ensureCover(for track: IPodTrack, store: IPodManifestStore) async {
        guard let albumId = track.albumId else { return }
        let folder = IPodPaths.albumFolder(track)
        guard await store.claimCover(folder) else { return }
        let path = folder + "/cover.jpg"
        // Already there: ours from before, or the user's own.
        guard !exists(path) else { return }
        guard let imageURL = api.artworkURL(for: albumId, size: 400),
              let (data, response) = try? await JellyfinAPIService.urlSession.data(from: imageURL),
              (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? false,
              let jpeg = try? IPodConverter.coverJPEG(from: data) else { return }
        try? fm.createDirectory(at: url(folder), withIntermediateDirectories: true)
        if (try? jpeg.write(to: url(path), options: .atomic)) != nil {
            await store.addCover(folder)
        }
    }

    // MARK: Removing

    /// Deletes a song and its `.lrc`. Only called with paths from the manifest.
    private func remove(path: String) {
        guard IPodPaths.isOurs(path) else { return }
        try? fm.removeItem(at: url(path))
        try? fm.removeItem(at: url(Self.lyricsPath(for: path)))
    }

    /// Removes folders that hold nothing but our `cover.jpg` (and Finder's leftovers),
    /// then their artist folder if that ended up empty too. Never goes above /Musica.
    private func pruneFolders(_ folders: Set<String>, store: IPodManifestStore) async {
        var pending = folders
        var visited = Set<String>()
        while let folder = pending.popFirst() {
            guard folder.hasPrefix(IPodPaths.musicFolder + "/"), visited.insert(folder).inserted else { continue }
            let folderURL = url(folder)
            guard let names = try? fm.contentsOfDirectory(atPath: folderURL.path) else { continue }
            let ownCover = await store.hasCover(folder)
            let junk = names.filter { name in
                (ownCover && name == "cover.jpg") || name == ".DS_Store" || name.hasPrefix("._")
            }
            guard junk.count == names.count else { continue }
            for name in junk { try? fm.removeItem(at: folderURL.appendingPathComponent(name)) }
            try? fm.removeItem(at: folderURL)
            await store.removeCover(folder)
            pending.insert((folder as NSString).deletingLastPathComponent)
        }
    }

    // MARK: Playlists

    /// `/Playlists/<Name>.m3u8` for every selected playlist; the ones no longer selected go.
    private func writePlaylists(store: IPodManifestStore, summary: inout IPodSummary) async {
        let manifest = await store.manifest
        let byId = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for old in manifest.playlists where IPodPaths.isOurs(old) { try? fm.removeItem(at: url(old)) }

        var written: [String] = []
        var used = Set<String>()
        do { try fm.createDirectory(at: url(IPodPaths.playlistFolder), withIntermediateDirectories: true) } catch {
            summary.errors.append("Playlist: \(error.localizedDescription)")
            return
        }
        for job in playlists {
            var name = IPodPaths.sanitize(job.name)
            var n = 2
            while !used.insert(name.lowercased()).inserted { name = "\(IPodPaths.sanitize(job.name)) (\(n))"; n += 1 }
            let path = "\(IPodPaths.playlistFolder)/\(name).m3u8"
            // Someone else's playlist with this name stays as it is.
            if exists(path), !manifest.playlists.contains(path) {
                summary.errors.append("Playlist “\(job.name)”: esiste già una playlist con questo nome sull'iPod, non la tocco")
                continue
            }
            var lines = ["#EXTM3U"]
            for id in job.trackIds {
                guard let item = manifest.items[id], let track = byId[id] else { continue }
                lines.append("#EXTINF:\(Int(track.duration.rounded())),\(track.artist) - \(track.title)")
                lines.append(item.path)
            }
            do {
                try (lines.joined(separator: "\n") + "\n").write(to: url(path), atomically: true, encoding: .utf8)
                written.append(path)
            } catch {
                summary.errors.append("Playlist “\(job.name)”: \(error.localizedDescription)")
            }
            report { $0.done += 1 }
        }
        await store.setPlaylists(written)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }
}
#endif
