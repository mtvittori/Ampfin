// JellyfinAPIService.swift
import Foundation

// Definiamo un errore personalizzato per gestire meglio i fallimenti API
enum APIError: Error, LocalizedError {
    case invalidURL
    case requestFailed(Error)
    case invalidResponse(Int)
    case decodingError(Error)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "L'URL della richiesta non è valido."
        case .requestFailed(let error): return "La richiesta al server è fallita: \(error.localizedDescription)"
        case .invalidResponse(let statusCode): return "Il server ha risposto con un errore (Status: \(statusCode))."
        case .decodingError(let error): return "Impossibile decodificare la risposta del server: \(error.localizedDescription)"
        }
    }
}

// URLSession delegate that accepts all TLS certificates (self-signed, expired, etc.)
// Used for Jellyfin servers with custom certificates.
// Conforms to URLSessionTaskDelegate to handle per-task auth challenges as well.
private class TrustAllCertsDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    // Session-level challenge
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleChallenge(challenge, completionHandler: completionHandler)
    }

    // Task-level challenge (used by data tasks, download tasks, etc.)
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleChallenge(challenge, completionHandler: completionHandler)
    }

    private func handleChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            // Accept all server certificates unconditionally
            SecTrustSetExceptions(serverTrust, SecTrustCopyExceptions(serverTrust))
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

class JellyfinAPIService {
    
    /// Shared URLSession that bypasses TLS certificate validation.
    /// Use this for all network requests to the Jellyfin server.
    static let urlSession: URLSession = {
        let delegate = TrustAllCertsDelegate()
        let config = URLSessionConfiguration.default
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    private static var deviceName: String {
        #if os(macOS)
        "macOS"
        #else
        "iOS"
        #endif
    }

    /// Stable per-install device id: Jellyfin ties sessions and tokens to it,
    /// so a fresh UUID on every request spawns a new "device" each time.
    private static let deviceId: String = {
        let key = "jellyfin_deviceid"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    private let serverUrl: String
    private var token: String = ""
    private var userId: String = ""
    
    // Il servizio viene inizializzato con i dati necessari
    init(serverUrl: String, token: String, userId: String) {
        self.serverUrl = serverUrl
        self.token = token
        self.userId = userId
    }
    
    // Costruttore vuoto per il login iniziale
    init(serverUrl: String) {
        self.serverUrl = serverUrl
    }
    
    // MARK: - Authentication
    // NOTA: il metodo di login è l'unico che modifica lo stato interno del servizio (token, userId)
    func login(username: String, password: String) async throws -> LoginResponse {
        guard let url = URL(string: "\(serverUrl)/Users/AuthenticateByName") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let authHeader = "MediaBrowser Client=\"amplifin\", Device=\"\(JellyfinAPIService.deviceName)\", DeviceId=\"\(JellyfinAPIService.deviceId)\", Version=\"1.0.0\""
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        
        struct LoginRequest: Codable { let Username: String; let Pw: String }
        request.httpBody = try JSONEncoder().encode(LoginRequest(Username: username, Pw: password))

        let (data, response) = try await JellyfinAPIService.urlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        
        do {
            let result = try JSONDecoder().decode(LoginResponse.self, from: data)
            // Aggiorna lo stato interno dopo un login riuscito
            self.token = result.AccessToken
            self.userId = result.User.Id
            return result
        } catch {
            throw APIError.decodingError(error)
        }
    }

    // MARK: - Data Fetching
    
    /// Fetches recently played tracks for the current user
    func fetchRecentlyPlayedTracks() async throws -> [AudioItem] {
        let libraryIds = try await fetchMusicLibraryIds()
        let tracks = try await fetchMerged(AudioResponse.self, from: libraryIds) { id in
            "/Users/\(userId)/Items?ParentId=\(id)&IncludeItemTypes=Audio&Recursive=true&Fields=AlbumArtists,Artists,AlbumId,Genres&SortBy=DatePlayed&SortOrder=Descending&Limit=20"
        }
        return Array(Self.mostRecentlyPlayed(tracks).prefix(20))
    }

    // MARK: - Playback reporting

    /// A listen as the official apps report it: start, progress every few seconds, stop
    /// with the real position. The start sets LastPlayedDate and adds one to the play count
    /// (what "recently played" and the mixes are built on); the whole session is what the
    /// Playback Reporting plugin records and what scrobbling plugins send on.
    /// (Jellyfin 12 answers 200 to /Users/{id}/PlayedItems but leaves the date alone when
    /// the song was already played, so that endpoint isn't used.)
    func reportPlaybackStart(itemId: String, sessionId: String, position: TimeInterval) async throws {
        try await postSession("/Sessions/Playing", body: [
            "ItemId": itemId, "PlaySessionId": sessionId, "PositionTicks": Self.ticks(position),
            "CanSeek": true, "IsPaused": false, "PlayMethod": "DirectPlay",
        ])
    }

    func reportPlaybackProgress(itemId: String, sessionId: String, position: TimeInterval, isPaused: Bool) async throws {
        try await postSession("/Sessions/Playing/Progress", body: [
            "ItemId": itemId, "PlaySessionId": sessionId, "PositionTicks": Self.ticks(position),
            "CanSeek": true, "IsPaused": isPaused, "PlayMethod": "DirectPlay",
            "EventName": isPaused ? "Pause" : "TimeUpdate",
        ])
    }

    func reportPlaybackStopped(itemId: String, sessionId: String, position: TimeInterval) async throws {
        try await postSession("/Sessions/Playing/Stopped", body: [
            "ItemId": itemId, "PlaySessionId": sessionId, "PositionTicks": Self.ticks(position),
        ])
    }

    private static func ticks(_ seconds: TimeInterval) -> Int64 {
        Int64(max(0, seconds) * 10_000_000)
    }

    private func postSession(_ path: String, body: [String: Any]) async throws {
        // A listen changes the history (last played, count): the next read must ask again.
        locked { historyCache = nil }
        guard let url = URL(string: "\(serverUrl)\(path)") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        addAuthHeader(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await JellyfinAPIService.urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw APIError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// Fetches recently added albums (ordered by DateCreated descending).
    /// Named as requested: fetchRecentAddedAlbums()
    func fetchRecentAddedAlbums() async throws -> [AlbumItem] {
        let libraryIds = try await fetchMusicLibraryIds()
        // DateCreated is Jellyfin's "date added" sort; DateAdded is not a valid SortBy value
        let albums = try await fetchMerged(AlbumResponse.self, from: libraryIds) { id in
            "/Users/\(userId)/Items?ParentId=\(id)&IncludeItemTypes=MusicAlbum&Recursive=true&Fields=ProductionYear,AlbumArtists,DateCreated,PremiereDate&SortBy=DateCreated,SortName&SortOrder=Descending&Limit=20"
        }
        return Array(Self.newestAdded(albums).prefix(20))
    }

    /// "server|user", the key the library choice is stored under.
    var librarySelectionScope: String { "\(serverUrl)|\(userId)" }

    /// Every music library the user can see (/Views is per user, so a library hidden from
    /// this account never shows up), whether or not it is switched on in Settings.
    /// Always asks the server (Settings shows it), and refreshes the copy the syncs use.
    func fetchMusicLibraries() async throws -> [LibraryView] {
        let response: UserViewsResponse = try await fetch(endpoint: "/Users/\(userId)/Views")
        let libraries = response.Items.filter { $0.CollectionType == "music" }
        locked { librariesCache = (Date(), libraries) }
        return libraries
    }

    /// The same list for the syncs: one sync used to ask for it three times, and the
    /// libraries of a server hardly change. Which ones are on is read at every call, so
    /// switching one in Settings needs no refresh here.
    private func cachedMusicLibraries() async throws -> [LibraryView] {
        if let cached = locked({ librariesCache }), Date().timeIntervalSince(cached.at) < Self.librariesMaxAge {
            return cached.libraries
        }
        return try await fetchMusicLibraries()
    }
    private static let librariesMaxAge: TimeInterval = 300
    private var librariesCache: (at: Date, libraries: [LibraryView])?

    /// The music libraries to use: the visible ones that are switched on in Settings.
    /// /Items takes a single ParentId, hence one query per library.
    func fetchMusicLibraryIds() async throws -> [String] {
        let all = try await cachedMusicLibraries()
        if all.isEmpty { throw APIError.invalidResponse(404) } // Simula un "not found"
        return MusicLibrarySelection.enabled(from: all, scope: librarySelectionScope).map(\.Id)
    }

    /// The service is used from several tasks at once.
    private let stateLock = NSLock()
    private func locked<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// Runs the same query on each library at once and joins the answers, one copy per Id.
    private func fetchMerged<R: ItemsResponse>(
        _ type: R.Type, from libraryIds: [String], endpoint: (String) -> String
    ) async throws -> [R.Element] {
        let lists = try await withThrowingTaskGroup(of: (Int, [R.Element]).self) { group in
            for (index, id) in libraryIds.enumerated() {
                let url = endpoint(id)
                group.addTask {
                    let response: R = try await self.fetch(endpoint: url)
                    return (index, response.items)
                }
            }
            var results: [(Int, [R.Element])] = []
            for try await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var seen = Set<String>()
        return lists.flatMap { $0 }.filter { seen.insert($0.id).inserted }
    }

    private static func newestAdded(_ albums: [AlbumItem]) -> [AlbumItem] {
        albums.sortedNewestFirst(by: \.dateAddedDate)
    }

    private static func mostRecentlyPlayed(_ tracks: [AudioItem]) -> [AudioItem] {
        tracks.sortedNewestFirst(by: { $0.UserData?.lastPlayed })
    }

    func fetchTracks(from libraryIds: [String]) async throws -> [AudioItem] {
        let tracks = try await fetchMerged(AudioResponse.self, from: libraryIds) { id in
            "/Users/\(userId)/Items?ParentId=\(id)&IncludeItemTypes=Audio&Recursive=true&Fields=AlbumArtists,Artists,AlbumId,Genres,DateCreated&SortBy=SortName"
        }
        // Each library comes sorted; with several, the join has to be sorted again
        guard libraryIds.count > 1 else { return tracks }
        return tracks.sorted { $0.Name.localizedStandardCompare($1.Name) == .orderedAscending }
    }
    
    func fetchAlbums(from libraryIds: [String]) async throws -> [AlbumItem] {
        // Newest first by DateCreated (Jellyfin's "date added"); DateAdded is not a valid SortBy value
        let albums = try await fetchMerged(AlbumResponse.self, from: libraryIds) { id in
            "/Users/\(userId)/Items?ParentId=\(id)&IncludeItemTypes=MusicAlbum&Recursive=true&Fields=ProductionYear,AlbumArtists,DateCreated,PremiereDate&SortBy=DateCreated,SortName&SortOrder=Descending"
        }
        return libraryIds.count > 1 ? Self.newestAdded(albums) : albums
    }
    
    /// MusicArtist items are global: Jellyfin ignores ParentId for them and answers with the
    /// same list whatever the library (checked on the server), so one query covers them all.
    /// With only some libraries on, /Artists (which does honour ParentId) tells which ones
    /// to keep.
    func fetchArtists(from libraryIds: [String]) async throws -> [ArtistItem] {
        let endpoint = "/Users/\(userId)/Items?IncludeItemTypes=MusicArtist&Recursive=true&SortBy=SortName"
        async let everyone: ArtistResponse = fetch(endpoint: endpoint)
        let total = try await cachedMusicLibraries().count
        guard libraryIds.count < total else { return try await everyone.Items }
        let inLibraries = try await fetchMerged(ArtistResponse.self, from: libraryIds) { id in
            "/Artists?userId=\(userId)&ParentId=\(id)"
        }
        let keep = Set(inLibraries.map(\.Id))
        return try await everyone.Items.filter { keep.contains($0.Id) }
    }

    func fetchAlbumTracks(albumId: String) async throws -> [AudioItem] {
        let endpoint = "/Users/\(userId)/Items?ParentId=\(albumId)&SortBy=SortName&SortOrder=Ascending&IncludeItemTypes=Audio&Fields=AlbumArtists,Artists,MediaSources,AlbumId"
        let response: AudioResponse = try await fetch(endpoint: endpoint)
        return response.Items
    }

    // MARK: - Playlists API (nuovi metodi)
    /// Recupera le playlist dell'utente
    func fetchUserPlaylists() async throws -> [PlaylistItem] {
        // Path tells the playlists made in Jellyfin from the .m3u files found in album folders.
        let endpoint = "/Users/\(userId)/Items?IncludeItemTypes=Playlist&Recursive=true&SortBy=SortName&Fields=Path,ChildCount,DateCreated"
        let response: PlaylistResponse = try await fetch(endpoint: endpoint)
        return response.Items
    }

    /// The songs of a playlist, in its order, with each entry's id (to remove it).
    func fetchPlaylistItems(playlistId: String) async throws -> [AudioItem] {
        let endpoint = "/Playlists/\(playlistId)/Items?UserId=\(userId)&Fields=AlbumArtists,Artists,AlbumId,Genres"
        let response: AudioResponse = try await fetch(endpoint: endpoint)
        return response.Items
    }

    /// Creates a playlist of songs for the current user; returns its id.
    @discardableResult
    func createPlaylist(name: String, itemIds: [String]) async throws -> String {
        guard let url = URL(string: "\(serverUrl)/Playlists") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        addAuthHeader(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "Name": name, "Ids": itemIds, "UserId": userId, "MediaType": "Audio",
        ])
        let (data, response) = try await JellyfinAPIService.urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["Id"] as? String ?? ""
    }

    func addToPlaylist(playlistId: String, itemIds: [String]) async throws {
        let ids = itemIds.joined(separator: ",")
        try await send("POST", path: "/Playlists/\(playlistId)/Items?ids=\(ids)&userId=\(userId)")
    }

    /// Takes entries (PlaylistItemId, not the song id) out of a playlist.
    func removeFromPlaylist(playlistId: String, entryIds: [String]) async throws {
        let ids = entryIds.joined(separator: ",")
        try await send("DELETE", path: "/Playlists/\(playlistId)/Items?entryIds=\(ids)")
    }

    func deletePlaylist(playlistId: String) async throws {
        try await send("DELETE", path: "/Items/\(playlistId)")
    }

    private func send(_ method: String, path: String) async throws {
        guard let url = URL(string: "\(serverUrl)\(path)") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        addAuthHeader(to: &request)
        let (_, response) = try await JellyfinAPIService.urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    // MARK: - Listening history

    /// The songs this user has played, most recent first, with play count and last date:
    /// what the mixes are worked out from. Each user gets their own.
    /// The Home's mixes and the statistics both ask for it at start-up: one request is shared
    /// (also while it is still running) and kept for `maxAge`; a report of a listen drops it.
    func fetchListeningHistory(limit: Int = 2000, maxAge: TimeInterval = 120) async throws -> [AudioItem] {
        let task = locked { () -> Task<[AudioItem], Error> in
            if let cached = historyCache, cached.limit == limit, Date().timeIntervalSince(cached.at) < maxAge {
                return cached.task
            }
            let task = Task { try await self.loadListeningHistory(limit: limit) }
            historyCache = (limit, Date(), task)
            return task
        }
        do {
            return try await task.value
        } catch {
            // A failure is not kept for the next caller.
            locked { if historyCache?.task == task { historyCache = nil } }
            throw error
        }
    }
    private var historyCache: (limit: Int, at: Date, task: Task<[AudioItem], Error>)?

    private func loadListeningHistory(limit: Int) async throws -> [AudioItem] {
        let libraryIds = try await fetchMusicLibraryIds()
        let tracks = try await fetchMerged(AudioResponse.self, from: libraryIds) { id in
            "/Users/\(userId)/Items?ParentId=\(id)&IncludeItemTypes=Audio&Recursive=true&Filters=IsPlayed&SortBy=DatePlayed&SortOrder=Descending&Limit=\(limit)&EnableUserData=true&Fields=AlbumArtists,Artists,AlbumId,Genres"
        }
        return libraryIds.count > 1 ? Array(Self.mostRecentlyPlayed(tracks).prefix(limit)) : tracks
    }

    // MARK: - Scrobbling statistics

    /// Runs a query on the Playback Reporting plugin's database and returns the rows as text.
    /// Throws APIError.invalidResponse with the status when the plugin isn't installed.
    func playbackReportingRows(sql: String) async throws -> [[String]] {
        guard let url = URL(string: "\(serverUrl)/user_usage_stats/submit_custom_query") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        addAuthHeader(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "CustomQueryString": sql, "ReplaceUserId": false,
        ])
        let (data, response) = try await JellyfinAPIService.urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        // The plugin answers "colums" (sic) and "results"; values come as strings.
        return try await Task.detached(priority: .userInitiated) {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = json["results"] as? [[Any]] else {
                throw APIError.decodingError(URLError(.cannotParseResponse))
            }
            return rows.map { row in row.map { cell in cell is NSNull ? "" : "\(cell)" } }
        }.value
    }

    /// Songs by id, in chunks, with what the statistics need (artist tags and album).
    func fetchItems(ids: [String]) async throws -> [AudioItem] {
        var items: [AudioItem] = []
        var start = 0
        while start < ids.count {
            let chunk = ids[start..<min(start + 100, ids.count)].joined(separator: ",")
            let endpoint = "/Users/\(userId)/Items?Ids=\(chunk)&Fields=AlbumArtists,Artists,AlbumId"
            let response: AudioResponse = try await fetch(endpoint: endpoint)
            items += response.Items
            start += 100
        }
        return items
    }

    // MARK: - URL Helpers

    func artworkURL(for itemId: String, size: Int = 200) -> URL? {
        // `tag` changes when the cover is changed from here, so caches keyed by URL load the new one.
        let tag = CoverRevisions.tag(for: itemId)
        return URL(string: "\(serverUrl)/Items/\(itemId)/Images/Primary?maxHeight=\(size)&maxWidth=\(size)&quality=90&tag=\(tag)&api_key=\(token)")
    }
    
    /// Any image of an item, e.g. `Primary` or `Backdrop/0` for an artist photo.
    func imageURL(for itemId: String, type: String, maxWidth: Int) -> URL? {
        return URL(string: "\(serverUrl)/Items/\(itemId)/Images/\(type)?maxWidth=\(maxWidth)&quality=85&api_key=\(token)")
    }

    func streamURL(for itemId: String) -> URL? {
        return URL(string: "\(serverUrl)/Audio/\(itemId)/stream?static=true&api_key=\(token)")
    }

    /// Returns a transcoded stream URL with the specified max bitrate (in kbps).
    func transcodedStreamURL(for itemId: String, maxBitrate: Int) -> URL? {
        return URL(string: "\(serverUrl)/Audio/\(itemId)/stream?audioBitRate=\(maxBitrate * 1000)&audioCodec=aac&static=false&api_key=\(token)")
    }

    /// Lossless FLAC converted by the server to 48 kHz (24 bit at most, stereo): for hi-res
    /// files, which download in a fraction of the time. No deviceId: the other stream URLs have none.
    func downsampledFlacStreamURL(for itemId: String) -> URL? {
        return URL(string: "\(serverUrl)/Audio/\(itemId)/stream.flac?static=false&audioCodec=flac&container=flac&audioSampleRate=48000&maxAudioSampleRate=48000&maxAudioBitDepth=24&audioChannels=2&api_key=\(token)")
    }

    // MARK: - Generic Fetch Helper
    
    private func fetch<T: Codable>(endpoint: String) async throws -> T {
        guard let url = URL(string: "\(serverUrl)\(endpoint)") else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        
        let (data, response) = try await JellyfinAPIService.urlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw APIError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        
        do {
            // DECODIFICA OFF-MAIN-THREAD per non bloccare l'interfaccia.
            return try await Task.detached(priority: .userInitiated) {
                try JSONDecoder().decode(T.self, from: data)
            }.value
        } catch {
            throw APIError.decodingError(error)
        }
    }
    
    // MARK: - Instant Mix

    /// Songs similar to this one (Jellyfin's Instant Mix), without the song itself.
    func fetchInstantMix(itemId: String, limit: Int = 30) async throws -> [AudioItem] {
        let endpoint = "/Items/\(itemId)/InstantMix?userId=\(userId)&limit=\(limit)&Fields=AlbumArtists,Artists,AlbumId,Genres"
        let response: AudioResponse = try await fetch(endpoint: endpoint)
        return response.Items.filter { $0.Id != itemId }
    }

    // MARK: - Media info

    /// Codec, rate and bit depth of one song, which the library lists leave out. Kept in
    /// `MediaInfoCache`; nil when the server doesn't answer (callers fall back to what they
    /// know: the stream then plays as the original).
    func fetchMediaSources(itemId: String) async -> [MediaSourceInfo]? {
        if let known = MediaInfoCache.shared.sources(for: itemId) { return known }
        guard let url = URL(string: "\(serverUrl)/Users/\(userId)/Items/\(itemId)?Fields=MediaSources") else { return nil }
        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        // Playback waits for this on hi-res songs: a slow server must not hold it for a minute.
        request.timeoutInterval = 5
        do {
            let (data, response) = try await JellyfinAPIService.urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            struct Response: Decodable { let MediaSources: [MediaSourceInfo]? }
            guard let sources = try JSONDecoder().decode(Response.self, from: data).MediaSources, !sources.isEmpty else { return nil }
            MediaInfoCache.shared.store(sources, for: itemId)
            return sources
        } catch {
            return nil
        }
    }

    // MARK: - Item details

    /// Everything the server knows about an item (song or album), as raw JSON.
    func fetchItemDetails(itemId: String) async throws -> [String: Any] {
        guard let url = URL(string: "\(serverUrl)/Users/\(userId)/Items/\(itemId)") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        let (data, response) = try await JellyfinAPIService.urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return json
    }

    // MARK: - Lyrics

    struct LyricLine: Identifiable, Equatable {
        let id: Int
        let text: String
        /// Seconds from the start, for synced lyrics; nil for plain text.
        let start: TimeInterval?
    }

    /// The song's lyrics from the server ([] when it has none).
    func fetchLyrics(itemId: String) async throws -> [LyricLine] {
        guard let url = URL(string: "\(serverUrl)/Audio/\(itemId)/Lyrics") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        let (data, response) = try await JellyfinAPIService.urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { return [] }
        if http.statusCode == 404 { return [] }
        guard (200...299).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lines = json["Lyrics"] as? [[String: Any]] else { return [] }
        return lines.enumerated().map { index, line in
            let ticks = (line["Start"] as? NSNumber)?.doubleValue
            return LyricLine(id: index, text: line["Text"] as? String ?? "",
                             start: ticks.map { $0 / 10_000_000 })
        }
    }

    // MARK: - Cover editing

    /// Whether this user may change images on the server (Jellyfin allows it to admins only).
    func isAdministrator() async throws -> Bool {
        guard let url = URL(string: "\(serverUrl)/Users/\(userId)") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        let (data, response) = try await JellyfinAPIService.urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["Policy"] as? [String: Any])?["IsAdministrator"] as? Bool ?? false
    }

    /// Covers the server's own providers suggest (MusicBrainz, TheAudioDB…).
    func fetchRemoteCovers(itemId: String) async throws -> [CoverCandidate] {
        guard let url = URL(string: "\(serverUrl)/Items/\(itemId)/RemoteImages?type=Primary&includeAllLanguages=true") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        let (data, response) = try await JellyfinAPIService.urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let images = json?["Images"] as? [[String: Any]] ?? []
        return images.compactMap { image in
            guard let link = image["Url"] as? String, let full = URL(string: link) else { return nil }
            return CoverCandidate(url: full, thumbnail: full,
                                  width: image["Width"] as? Int, height: image["Height"] as? Int,
                                  source: image["ProviderName"] as? String ?? "Jellyfin", title: nil)
        }
    }

    /// Has the server download `imageURL` and make it the item's cover.
    func setCover(itemId: String, imageURL: URL) async throws {
        var components = URLComponents(string: "\(serverUrl)/Items/\(itemId)/RemoteImages/Download")
        components?.queryItems = [URLQueryItem(name: "type", value: "Primary"),
                                  URLQueryItem(name: "imageUrl", value: imageURL.absoluteString)]
        // `+` is legal in a query but the server would read it as a space.
        let query = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = query
        guard let url = components?.url else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        addAuthHeader(to: &request)
        let (_, response) = try await JellyfinAPIService.urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// Uploads an image as the item's cover. Jellyfin 12 wants the body in base64 (raw bytes give 500).
    func uploadCover(itemId: String, jpegData: Data) async throws {
        guard let url = URL(string: "\(serverUrl)/Items/\(itemId)/Images/Primary") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        addAuthHeader(to: &request)
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = jpegData.base64EncodedData()
        let (_, response) = try await JellyfinAPIService.urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    // MARK: - Settings backup

    /// Display Preferences of client "amplifin" for this user: Jellyfin keeps them per
    /// user on the server, and their CustomPrefs hold the settings backup.
    private var backupPreferencesURL: URL? {
        URL(string: "\(serverUrl)/DisplayPreferences/amplifin-backup?userId=\(userId)&client=amplifin")
    }

    private func loadBackupPreferences() async throws -> [String: Any] {
        guard let url = backupPreferencesURL else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        let (data, response) = try await JellyfinAPIService.urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decodingError(CocoaError(.coderReadCorrupt))
        }
        return json
    }

    /// The backup on the server, or nil when there isn't one yet.
    func loadSettingsBackup() async throws -> (settings: [String: Any], date: Date)? {
        let prefs = try await loadBackupPreferences()
        guard let custom = prefs["CustomPrefs"] as? [String: Any],
              let encoded = custom["amplifinBackup"] as? String else { return nil }
        let date = (custom["amplifinBackupDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        return (try SettingsBackupCoding.decode(encoded), date)
    }

    /// Stores the backup, keeping every other preference as the server had it.
    func saveSettingsBackup(_ settings: [String: Any], date: Date) async throws {
        guard let url = backupPreferencesURL else { throw APIError.invalidURL }
        var prefs = try await loadBackupPreferences()
        var custom = prefs["CustomPrefs"] as? [String: Any] ?? [:]
        custom["amplifinBackup"] = try SettingsBackupCoding.encode(settings)
        custom["amplifinBackupDate"] = ISO8601DateFormatter().string(from: date)
        prefs["CustomPrefs"] = custom
        prefs["Client"] = "amplifin"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        addAuthHeader(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: prefs)
        let (_, response) = try await JellyfinAPIService.urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private func addAuthHeader(to request: inout URLRequest) {
        let authHeader = "MediaBrowser Client=\"amplifin\", Device=\"\(JellyfinAPIService.deviceName)\", DeviceId=\"\(JellyfinAPIService.deviceId)\", Version=\"1.0.0\", Token=\"\(token)\""
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
}
