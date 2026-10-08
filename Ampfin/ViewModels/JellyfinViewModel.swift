// In ViewModels/JellyfinViewModel.swift
import Foundation
import Combine
import Network
import WidgetKit


@MainActor // Garantisce che tutte le modifiche alle property @Published avvenga sul Main Thread
class JellyfinViewModel: ObservableObject {
    // MARK: - Shared Instance (for CarPlay access)
    static var shared: JellyfinViewModel?

    // MARK: - Published Properties (Stato dell'UI)
    @Published private(set) var audioItems: [AudioItem] = []
    @Published private(set) var albums: [AlbumItem] = [] {
        didSet { albumArtistById = nil }
    }
    /// Album id → album artist, built once per library load (rows ask for it constantly).
    private var albumArtistById: [String: String]?
    /// Artists after the merge rules (see ArtistMerge.swift); `rawArtists` is the server list.
    @Published private(set) var artists: [ArtistItem] = []
    private var rawArtists: [ArtistItem] = [] {
        didSet { rebuildArtistIndex() }
    }
    private var artistIndex = ArtistIndex.empty
    @Published private(set) var allAvailableGenres: [String] = []
    
    @Published private(set) var selectedAlbumTracks: [AudioItem] = []
    
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingAlbum = false
    @Published var errorMessage: String?
    @Published private(set) var isLoggedIn = false
    
    // Global search query (toolbar)
    @Published var globalSearchQuery: String = ""
    
    @Published var repeatMode: RepeatMode = .off

    // MARK: - Player State (inoltrato dal Player Manager)
    @Published private(set) var currentlyPlayingItem: AudioItem?
    @Published private(set) var isPlaying: Bool = false
    @Published var onIsPlayingChanged: ((Bool) -> Void)?
    /// Playback position. It ticks twice a second, so it is published by its own small
    /// object: as a property of the view model it redrew every screen observing it.
    let clock = PlaybackClock()
    var currentTime: TimeInterval { clock.time }

    @Published private(set) var recentlyPlayedTracks: [AudioItem] = []
    @Published private(set) var recentlyAddedAlbums: [AlbumItem] = [] // cached recently added albums

    /// Derived from `recentlyPlayedTracks` (reliably sorted server-side by DatePlayed) rather than
    /// querying MusicAlbum items by DatePlayed directly: Jellyfin only tracks LastPlayedDate on the
    /// individual track, not aggregated onto the album folder, so that query returned stale/empty results.
    var recentlyPlayedAlbums: [AlbumItem] {
        var seenAlbumIds = Set<String>()
        var result: [AlbumItem] = []
        for track in recentlyPlayedTracks {
            guard let albumId = track.AlbumId, !seenAlbumIds.contains(albumId) else { continue }
            guard let album = albums.first(where: { $0.id == albumId }) else { continue }
            seenAlbumIds.insert(albumId)
            result.append(album)
        }
        return result
    }

    // Cache metadata
    private var recentlyAddedAlbumsFetchDate: Date?
    private let recentlyAddedAlbumsCacheTTL: TimeInterval = 60 * 5 // 5 minutes

    // MARK: - Favorites (albums + tracks + playlists)
    // Conserviamo solo gli id degli item preferiti per semplicità
    @Published private(set) var favoriteAlbumIds: Set<String> = []
    @Published private(set) var favoriteTrackIds: Set<String> = []
    @Published private(set) var favoritePlaylistIds: Set<String> = []

    var favoriteAlbums: [AlbumItem] {
        // Mantieni l'ordine come appare in `albums`
        return albums.filter { favoriteAlbumIds.contains($0.id) }
    }
    var favoriteTracks: [AudioItem] {
        return audioItems.filter { favoriteTrackIds.contains($0.id) }
    }
    // Nota: le playlist vengono gestite tramite PlaylistViewModel, per mostrare gli oggetti playlists completi puoi creare una PlaylistViewModel e filtrare lì

    // MARK: - Streaming Quality
    enum StreamQuality: String, CaseIterable, Identifiable {
        case original = "original"
        case high = "320"     // 320 kbps
        case medium = "192"   // 192 kbps
        case low = "128"      // 128 kbps

        var id: String { rawValue }

        var label: String {
            switch self {
            case .original: return "Originale"
            case .high: return "320 kbps"
            case .medium: return "192 kbps"
            case .low: return "128 kbps"
            }
        }

        var bitrate: Int? {
            switch self {
            case .original: return nil
            case .high: return 320
            case .medium: return 192
            case .low: return 128
            }
        }
    }

    @Published var streamQualityWifi: StreamQuality = .original {
        didSet { UserDefaults.standard.set(streamQualityWifi.rawValue, forKey: StorageKeys.streamQualityWifi) }
    }
    @Published var streamQualityCellular: StreamQuality = .original {
        didSet { UserDefaults.standard.set(streamQualityCellular.rawValue, forKey: StorageKeys.streamQualityCellular) }
    }

    // MARK: - Library Refresh Interval
    enum LibraryRefreshInterval: String, CaseIterable, Identifiable {
        case oneHour = "3600"
        case sixHours = "21600"
        case twelveHours = "43200"
        case oneDay = "86400"
        case threeDays = "259200"
        case oneWeek = "604800"
        case manual = "manual"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .oneHour: return "Ogni ora"
            case .sixHours: return "Ogni 6 ore"
            case .twelveHours: return "Ogni 12 ore"
            case .oneDay: return "Ogni giorno"
            case .threeDays: return "Ogni 3 giorni"
            case .oneWeek: return "Ogni settimana"
            case .manual: return "Solo manuale"
            }
        }

        var timeInterval: TimeInterval? {
            if self == .manual { return nil }
            return TimeInterval(rawValue)
        }
    }

    @Published var libraryRefreshInterval: LibraryRefreshInterval = .sixHours {
        didSet { UserDefaults.standard.set(libraryRefreshInterval.rawValue, forKey: StorageKeys.libraryRefreshInterval) }
    }
    @Published private(set) var lastLibrarySyncDate: Date?

    // MARK: - Servizi e Manager
    private(set) var apiService: JellyfinAPIService?
    private var playbackReporter: PlaybackReporter?
    private(set) var playerManager: AudioPlayerManager!
    
    // MARK: - Credenziali e Storage
    // Server URL è pubblicata così la UI può leggere e aggiornarla
    @Published var serverUrl: String
    
    // Connection test feedback
    @Published var isTestingConnection: Bool = false
    @Published var lastConnectionTestResult: Bool? = nil // true = success, false = failed, nil = no test yet
    
    private enum StorageKeys {
        static let token = "jellyfin_accesstoken"
        static let userId = "jellyfin_userid"
        static let serverUrl = "jellyfin_serverurl"
        static let favoriteAlbums = "jellyfin_favorite_albums"
        static let favoriteTracks = "jellyfin_favorite_tracks"
        static let favoritePlaylists = "jellyfin_favorite_playlists"
        static let streamQualityWifi = "stream_quality_wifi"
        static let streamQualityCellular = "stream_quality_cellular"
        static let libraryRefreshInterval = "library_refresh_interval"
    }
    
    private var token: String = ""
    private var userId: String = ""
    /// The logged-in user: mixes and history are per user.
    var currentUserId: String { userId }
    
    private var cancellables = Set<AnyCancellable>()
    private var serverUrlCancellable: AnyCancellable?
    
    // Network monitoring for quality switching
    private let networkMonitor = NWPathMonitor()
    private var isOnCellular: Bool = false



    // MARK: - Init
    init() {
        // Leggi la serverUrl salvata (se presente) o usa stringa vuota (nessun default hardcodato)
        self.serverUrl = UserDefaults.standard.string(forKey: StorageKeys.serverUrl) ?? ""
        
        if !serverUrl.isEmpty {
            self.apiService = JellyfinAPIService(serverUrl: serverUrl)
        } else {
            self.apiService = nil
        }
        
        // Carica preferiti salvati
        if let savedAlbums = UserDefaults.standard.array(forKey: StorageKeys.favoriteAlbums) as? [String] {
            self.favoriteAlbumIds = Set(savedAlbums)
        } else {
            self.favoriteAlbumIds = []
        }
        if let savedTracks = UserDefaults.standard.array(forKey: StorageKeys.favoriteTracks) as? [String] {
            self.favoriteTrackIds = Set(savedTracks)
        } else {
            self.favoriteTrackIds = []
        }
        if let savedPlaylists = UserDefaults.standard.array(forKey: StorageKeys.favoritePlaylists) as? [String] {
            self.favoritePlaylistIds = Set(savedPlaylists)
        } else {
            self.favoritePlaylistIds = []
        }
        
        // Carica qualità streaming salvate
        if let wifiRaw = UserDefaults.standard.string(forKey: StorageKeys.streamQualityWifi),
           let quality = StreamQuality(rawValue: wifiRaw) {
            self.streamQualityWifi = quality
        }
        if let cellularRaw = UserDefaults.standard.string(forKey: StorageKeys.streamQualityCellular),
           let quality = StreamQuality(rawValue: cellularRaw) {
            self.streamQualityCellular = quality
        }
        
        // Carica intervallo refresh libreria
        if let intervalRaw = UserDefaults.standard.string(forKey: StorageKeys.libraryRefreshInterval),
           let interval = LibraryRefreshInterval(rawValue: intervalRaw) {
            self.libraryRefreshInterval = interval
        }
        if let meta = LibraryCacheService.shared.loadMetadata() {
            self.lastLibrarySyncDate = meta.lastSyncDate
        }
        
        // Configuriamo un debounce sul serverUrl: persiste subito, ma (ri)crea apiService solo dopo pausa di digitazione
        serverUrlCancellable = $serverUrl
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] newValue in
                Task { @MainActor in
                    self?.createApiServiceIfNeeded(from: newValue)
                }
            }
        
        // Avvia il monitor di rete per distinguere WiFi/cellulare
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isOnCellular = path.usesInterfaceType(.cellular)
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "net.monitor"))
        
        // Carica le credenziali e, se presenti e se abbiamo una serverUrl, avvia il setup
        loadCredentials()
        if !token.isEmpty && !userId.isEmpty && !serverUrl.isEmpty {
            setupAuthenticatedSession()
            self.isLoggedIn = true
        }

        // Store shared reference for CarPlay access (after all properties initialized)
        // Merge rules changed: rebuild the artist list (on the next turn, once the change has landed).
        ArtistMergeStore.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildArtistIndex() }
            .store(in: &cancellables)

        JellyfinViewModel.shared = self
    }
    
    // MARK: - Favorites API
    /// Toggle favorito per album (aggiunge o rimuove l'id dall'insieme) e persiste
    func toggleFavoriteAlbum(_ albumId: String) {
        if favoriteAlbumIds.contains(albumId) {
            favoriteAlbumIds.remove(albumId)
        } else {
            favoriteAlbumIds.insert(albumId)
        }
        // Persistiamo come array
        let array = Array(favoriteAlbumIds)
        UserDefaults.standard.set(array, forKey: StorageKeys.favoriteAlbums)
    }
    
    func isAlbumFavorite(_ albumId: String) -> Bool {
        favoriteAlbumIds.contains(albumId)
    }

    /// Toggle favorito per traccia e persiste
    func toggleFavoriteTrack(_ trackId: String) {
        if favoriteTrackIds.contains(trackId) {
            favoriteTrackIds.remove(trackId)
        } else {
            favoriteTrackIds.insert(trackId)
        }
        let array = Array(favoriteTrackIds)
        UserDefaults.standard.set(array, forKey: StorageKeys.favoriteTracks)
    }
    
    func isTrackFavorite(_ trackId: String) -> Bool {
        favoriteTrackIds.contains(trackId)
    }

    /// Toggle favorito per playlist e persiste
    func toggleFavoritePlaylist(_ playlistId: String) {
        if favoritePlaylistIds.contains(playlistId) {
            favoritePlaylistIds.remove(playlistId)
        } else {
            favoritePlaylistIds.insert(playlistId)
        }
        let array = Array(favoritePlaylistIds)
        UserDefaults.standard.set(array, forKey: StorageKeys.favoritePlaylists)
    }

    func isPlaylistFavorite(_ playlistId: String) -> Bool {
        favoritePlaylistIds.contains(playlistId)
    }
    
    // MARK: - Server URL update helper (public)
    /// Aggiorna la server URL (trimma e persiste su UserDefaults).
    /// Non ricrea immediatamente l'apiService (debounce è gestito dal publisher).
    func updateServerUrl(_ newUrl: String) {
        let trimmed = newUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        // Aggiorna Published (attiva il debounce pipeline)
        self.serverUrl = trimmed
        // Persistiamo subito la scelta così l'utente non la perde
        UserDefaults.standard.set(trimmed, forKey: StorageKeys.serverUrl)
        // Nota: la (ri)creazione di apiService avverrà dopo il debounce
    }
    
    private func createApiServiceIfNeeded(from urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            self.apiService = nil
            return
        }
        // Solo se ha formato plausibile (http/https) creiamo il servizio
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else {
            // Non creeremo apiService se il formato non è valido; l'UI può comunque mostrare validazione
            self.apiService = nil
            return
        }
        if !token.isEmpty && !userId.isEmpty {
            self.apiService = JellyfinAPIService(serverUrl: trimmed, token: token, userId: userId)
        } else {
            self.apiService = JellyfinAPIService(serverUrl: trimmed)
        }
    }
    
    /// Testa la raggiungibilità del server Jellyfin.
    /// Usa l'endpoint pubblico "/System/Info/Public"; aggiorna isTestingConnection e lastConnectionTestResult.
    /// Se il protocollo originale fallisce, tenta automaticamente l'alternativo (HTTPS↔HTTP) e aggiorna la URL.
    func testServerConnection(serverURL: String? = nil) async -> Bool {
        isTestingConnection = true
        errorMessage = nil
        lastConnectionTestResult = nil
        
        let base = (serverURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? serverUrl)
        guard !base.isEmpty else {
            self.errorMessage = "URL non valida."
            isTestingConnection = false
            lastConnectionTestResult = false
            return false
        }
        
        if let working = await resolveWorkingURL(base: base) {
            if working != base {
                self.updateServerUrl(working)
            }
            isTestingConnection = false
            lastConnectionTestResult = true
            return true
        }
        
        self.errorMessage = "Server non raggiungibile."
        isTestingConnection = false
        lastConnectionTestResult = false
        return false
    }
    
    /// Tries the given URL and, if it fails, tries the opposite scheme (HTTPS↔HTTP).
    /// Returns the first working base URL, or nil if neither works.
    private func resolveWorkingURL(base: String) async -> String? {
        let lower = base.lowercased()
        
        // Build the two candidates: original first, then the alternate scheme
        var candidates = [base]
        if lower.hasPrefix("https://") {
            candidates.append("http://" + base.dropFirst("https://".count))
        } else if lower.hasPrefix("http://") {
            candidates.append("https://" + base.dropFirst("http://".count))
        }
        
        for candidate in candidates {
            if await pingServer(base: candidate) {
                return candidate
            }
        }
        return nil
    }
    
    /// Low-level reachability check. Does NOT modify any published UI state.
    private func pingServer(base: String) async -> Bool {
        guard let url = URL(string: "\(base)/System/Info/Public") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        
        do {
            let (_, response) = try await JellyfinAPIService.urlSession.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return true
            }
        } catch {
            // Connection failed — caller will try the next candidate
        }
        return false
    }
    
    // MARK: - Authentication
    
    /// Effettua il login verso Jellyfin. Se `serverURL` è fornita, la usa per inizializzare il servizio prima del login.
    /// Tenta automaticamente il fallback HTTPS↔HTTP se la connessione fallisce.
    func login(username: String, password: String, serverURL: String? = nil) async {
        isLoading = true
        errorMessage = nil
        
        // Se l'utente ha fornito una URL, aggiorna la serverUrl e ricrea apiService (immediato per il login)
        if let provided = serverURL?.trimmingCharacters(in: .whitespacesAndNewlines), !provided.isEmpty {
            // Resolve the working protocol (tries provided first, then alternate scheme)
            let working = await resolveWorkingURL(base: provided) ?? provided
            self.serverUrl = working
            self.apiService = JellyfinAPIService(serverUrl: working)
            UserDefaults.standard.set(working, forKey: StorageKeys.serverUrl)
        }
        
        guard let api = apiService else {
            self.errorMessage = "Server URL non impostata."
            isLoading = false
            return
        }
        
        do {
            // usa il servizio API corrente (inizializzato con la serverUrl corretta)
            let response = try await api.login(username: username, password: password)
            
            // Salva le credenziali nel ViewModel
            self.token = response.AccessToken
            self.userId = response.User.Id
            
            // Salva su storage e configura sessione autenticata
            saveCredentials()
            self.isLoggedIn = true
            setupAuthenticatedSession()
            
            // Carica i dati della libreria dopo il login
            await fetchAllLibraryData()
        } catch {
            // Mostra errore leggibile
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            self.isLoggedIn = false
        }
        isLoading = false
    }
    
    /// Esegue il logout: ferma il player, ripulisce lo stato e rimuove le credenziali locali.
    func logout() {
        // Ferma e pulisci il player manager (se presente)
        if let manager = playerManager {
            manager.stop()
        }
        
        // Reimposta lo stato dell'app
        MixStore.shared.reset()
        ScrobbleStatsStore.shared.reset()
        audioItems = []
        albums = []
        rawArtists = []
        allAvailableGenres = []
        selectedAlbumTracks = []
        currentlyPlayingItem = nil
        isPlaying = false
        clock.time = 0
        recentlyPlayedTracks = []
        recentlyAddedAlbums = []
        
        // Credenziali e flags
        token = ""
        userId = ""
        isLoggedIn = false
        errorMessage = nil
        
        // Rimuovi dal persistent storage (ma mantieni la serverUrl)
        clearCredentials()
        clearLibraryCache()
        
        // Ricrea il servizio API senza credenziali (ma con la stessa serverUrl pronta per un nuovo login)
        if !serverUrl.isEmpty {
            self.apiService = JellyfinAPIService(serverUrl: serverUrl)
        } else {
            self.apiService = nil
        }
        
        // Clear widget data
        syncNowPlayingToWidget(item: nil, playing: false)
    }
    
    // MARK: - Fetch helpers (ora controllano che apiService sia disponibile)
    /// Kept as a thin wrapper (rather than renaming) since `recentlyPlayedAlbums` is now derived
    /// from `recentlyPlayedTracks` — see that property's doc comment for why.
    func fetchRecentlyPlayedAlbums() async {
        await fetchRecentlyPlayedTracks()
    }

    func fetchRecentAddedAlbums() async {
        guard isLoggedIn, let api = apiService else { return }
        do {
            let albums = try await api.fetchRecentAddedAlbums()
            self.recentlyAddedAlbums = albums
            self.recentlyAddedAlbumsFetchDate = Date()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
    
    func fetchRecentlyAddedAlbumsIfNeeded(force: Bool = false) async {
        guard isLoggedIn else { return }
        if !force,
           let fetchedAt = recentlyAddedAlbumsFetchDate,
           !recentlyAddedAlbums.isEmpty,
           Date().timeIntervalSince(fetchedAt) < recentlyAddedAlbumsCacheTTL {
            return
        }
        await fetchRecentAddedAlbums()
    }
    
    func fetchRecentlyPlayedAlbumsIfNeeded(force: Bool = false) async {
        await fetchRecentlyPlayedTracksIfNeeded(force: force)
    }

    func fetchRecentlyPlayedTracks() async {
        guard let api = apiService else { return }
        do {
            self.recentlyPlayedTracks = try await api.fetchRecentlyPlayedTracks()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    /// Moves a song that just played to the top of "recently played" without waiting for the server.
    func noteRecentlyPlayed(_ itemId: String) {
        guard let item = currentlyPlayingItem?.Id == itemId ? currentlyPlayingItem
                : recentlyPlayedTracks.first(where: { $0.Id == itemId }) else { return }
        recentlyPlayedTracks = [item] + recentlyPlayedTracks.filter { $0.Id != itemId }
    }

    func fetchRecentlyPlayedTracksIfNeeded(force: Bool = false) async {
        guard isLoggedIn else { return }
        if !force && !recentlyPlayedTracks.isEmpty {
            return
        }
        await fetchRecentlyPlayedTracks()
    }
    
    func fetchAllLibraryData() async {
        guard isLoggedIn, let api = apiService else {
            self.errorMessage = "Non autenticato o server non configurato."
            return
        }
        isLoading = true
        
        do {
            let libraryId = try await api.fetchMusicLibraryId()
            
            async let tracks = api.fetchTracks(from: libraryId)
            async let albums = api.fetchAlbums(from: libraryId)
            async let artists = api.fetchArtists(from: libraryId)
            
            let (fetchedTracks, fetchedAlbums, fetchedArtists) = try await (tracks, albums, artists)
            
            self.audioItems = fetchedTracks
            self.albums = Self.newestFirst(fetchedAlbums)
            self.rawArtists = fetchedArtists
            self.allAvailableGenres = Array(Set(fetchedTracks.compactMap { $0.Genres }.flatMap { $0 })).sorted()

            // Persist to disk cache
            LibraryCacheService.shared.saveLibrary(
                tracks: self.audioItems,
                albums: self.albums,
                artists: self.rawArtists,
                genres: self.allAvailableGenres
            )
            self.lastLibrarySyncDate = Date()

            // Keep "Aggiunti di recente" in step with the library sync
            await fetchRecentlyAddedAlbumsIfNeeded(force: true)
        } catch {
            print("[Library] Fetch failed: \(error)")
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "Errore nel caricamento della libreria."
        }
        isLoading = false
    }
    
    func fetchAlbumTracks(albumId: String) async {
        guard let api = apiService else {
            self.errorMessage = "Server URL non impostata."
            return
        }
        isLoadingAlbum = true
        selectedAlbumTracks = []
        do {
            self.selectedAlbumTracks = try await api.fetchAlbumTracks(albumId: albumId)
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "Errore nel caricamento delle tracce dell'album."
        }
        isLoadingAlbum = false
    }

    /// Fetches album tracks without mutating shared state (for CarPlay use).
    func fetchAlbumTracksDirectly(albumId: String) async -> [AudioItem] {
        guard let api = apiService else { return [] }
        do {
            return try await api.fetchAlbumTracks(albumId: albumId)
        } catch {
            return []
        }
    }

    // MARK: - Library Cache

    /// Loads the library from disk cache into @Published properties.
    /// Returns true if cache was loaded successfully.
    func loadLibraryFromCacheIfAvailable() async -> Bool {
        guard let cached = await LibraryCacheService.shared.loadLibrary() else {
            return false
        }
        self.audioItems = cached.tracks
        self.albums = Self.newestFirst(cached.albums)
        self.rawArtists = cached.artists
        self.allAvailableGenres = cached.genres
        // A cache written before the albums carried their date: sync again (the stale check
        // sees no sync date), or "Aggiunti di recente" keeps the old order.
        let hasDates = cached.albums.contains { $0.DateCreated != nil }
        self.lastLibrarySyncDate = hasDates || cached.albums.isEmpty ? cached.lastSyncDate : nil
        return true
    }

    /// Newest album first. Stable: albums with the same (or no) date keep the server's
    /// order — Swift's sort isn't, and with no dates at all it shuffled the list.
    private static func newestFirst(_ albums: [AlbumItem]) -> [AlbumItem] {
        let dated: [(offset: Int, date: Date)] = albums.indices.map { ($0, albums[$0].dateAddedDate ?? .distantPast) }
        let order = dated.sorted { a, b in
            if a.date != b.date { return a.date > b.date }
            return a.offset < b.offset
        }
        return order.map { albums[$0.offset] }
    }

    /// Returns true if the library cache has expired based on the user's refresh interval.
    func isLibraryCacheStale() -> Bool {
        guard let interval = libraryRefreshInterval.timeInterval else {
            return false // "manual" mode — never auto-stale
        }
        guard let lastSync = lastLibrarySyncDate else {
            return true // no sync recorded
        }
        return Date().timeIntervalSince(lastSync) > interval
    }

    /// Clears the library disk cache and resets the sync date.
    func clearLibraryCache() {
        LibraryCacheService.shared.clearAll()
        self.lastLibrarySyncDate = nil
    }

    // MARK: - Public Helper Methods
    
    func artworkURL(for itemId: String, size: Int = 200) -> URL? {
        return apiService?.artworkURL(for: itemId, size: size)
    }

    // MARK: - Changing a cover

    /// Bumped after a cover change, so every view rebuilds its artwork URLs.
    @Published private(set) var coverRevision = 0

    func canEditCovers() async -> Bool {
        (try? await apiService?.isAdministrator()) ?? false
    }

    func remoteCovers(for itemId: String) async -> [CoverCandidate] {
        (try? await apiService?.fetchRemoteCovers(itemId: itemId)) ?? []
    }

    func setCover(for itemId: String, to candidate: CoverCandidate) async throws {
        guard let api = apiService else { throw APIError.invalidURL }
        try await api.setCover(itemId: itemId, imageURL: candidate.url)
        coverDidChange(itemId)
    }

    func uploadCover(for itemId: String, jpegData: Data) async throws {
        guard let api = apiService else { throw APIError.invalidURL }
        try await api.uploadCover(itemId: itemId, jpegData: jpegData)
        coverDidChange(itemId)
    }

    private func coverDidChange(_ itemId: String) {
        CoverRevisions.bump(itemId)
        coverRevision += 1
    }
    
    func streamURL(for itemId: String) -> URL? {
        return apiService?.streamURL(for: itemId)
    }

    // MARK: - Artist images

    /// Photos to try for an artist, best first: the wide backdrop, then the portrait.
    /// When the tags are unknown (library cache from an older build) both are tried
    /// and the loader skips whichever the server doesn't have.
    func artistImageURLs(for artist: ArtistItem, maxWidth: Int = 1600) -> [URL] {
        guard let api = apiService else { return [] }
        var urls: [URL] = []
        if artist.BackdropImageTags.map({ !$0.isEmpty }) ?? true,
           let url = api.imageURL(for: artist.Id, type: "Backdrop/0", maxWidth: maxWidth) {
            urls.append(url)
        }
        if artist.ImageTags?["Primary"] != nil || artist.ImageTags == nil,
           let url = api.imageURL(for: artist.Id, type: "Primary", maxWidth: maxWidth) {
            urls.append(url)
        }
        return urls
    }

    /// Artist photos for a track, falling back to the album cover so the
    /// background is never empty.
    func artistImageURLs(for item: AudioItem, maxWidth: Int = 1600) -> [URL] {
        var urls: [URL] = []
        var names = (item.AlbumArtists?.map(\.Name) ?? []) + (item.Artists ?? [])
        // Untagged files: fall back to the album's artist.
        if names.isEmpty, let albumArtist = albums.first(where: { $0.Id == item.AlbumId })?.AlbumArtist {
            names.append(albumArtist)
        }
        for name in names {
            if let artist = artist(named: name) {
                urls += artistImageURLs(for: artist, maxWidth: maxWidth)
            }
        }
        if urls.isEmpty, let id = item.AlbumArtists?.first?.Id, let api = apiService {
            urls += [api.imageURL(for: id, type: "Backdrop/0", maxWidth: maxWidth),
                     api.imageURL(for: id, type: "Primary", maxWidth: maxWidth)].compactMap { $0 }
        }
        if let cover = artworkURL(for: item.AlbumId ?? item.id, size: 800) {
            urls.append(cover)
        }
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    /// Artist to show for a track, using the album's artist for untagged files.
    func artistName(for item: AudioItem) -> String? {
        if let name = item.mainArtistName { return name }
        guard let albumId = item.AlbumId else { return nil }
        if albumArtistById == nil {
            albumArtistById = Dictionary(albums.compactMap { album in album.AlbumArtist.map { (album.Id, $0) } },
                                         uniquingKeysWith: { first, _ in first })
        }
        return albumArtistById?[albumId]
    }

    func artist(named name: String?) -> ArtistItem? {
        guard let name, !name.isEmpty else { return nil }
        if let artist = artistIndex.artist(named: name) { return artist }
        // A combined credit ("A feat. B") belongs to its first artist.
        return credits(of: name).dropFirst().lazy.compactMap { self.artistIndex.artist(named: $0) }.first
    }

    func itemDetails(id: String) async -> [String: Any]? {
        guard let api = apiService else { return nil }
        return try? await api.fetchItemDetails(itemId: id)
    }

    func lyrics(for item: AudioItem) async -> [JellyfinAPIService.LyricLine] {
        guard let api = apiService else { return [] }
        return (try? await api.fetchLyrics(itemId: item.Id)) ?? []
    }

    /// Reads favorites and playback settings again, after a backup has been restored.
    func reloadSettingsFromDefaults() {
        let defaults = UserDefaults.standard
        favoriteAlbumIds = Set(defaults.array(forKey: StorageKeys.favoriteAlbums) as? [String] ?? [])
        favoriteTrackIds = Set(defaults.array(forKey: StorageKeys.favoriteTracks) as? [String] ?? [])
        favoritePlaylistIds = Set(defaults.array(forKey: StorageKeys.favoritePlaylists) as? [String] ?? [])
        if let raw = defaults.string(forKey: StorageKeys.streamQualityWifi), let q = StreamQuality(rawValue: raw) {
            streamQualityWifi = q
        }
        if let raw = defaults.string(forKey: StorageKeys.streamQualityCellular), let q = StreamQuality(rawValue: raw) {
            streamQualityCellular = q
        }
        if let raw = defaults.string(forKey: StorageKeys.libraryRefreshInterval), let i = LibraryRefreshInterval(rawValue: raw) {
            libraryRefreshInterval = i
        }
    }

    /// How many artist entries the server has, before merging.
    var rawArtistCount: Int { rawArtists.count }

    /// The merged artist whose names include `key` (a comparison key).
    func artist(forKey key: String) -> ArtistItem? {
        artists.first { artist in (artist.mergedNames ?? [artist.Name]).contains { ArtistMergeStore.key($0) == key } }
    }

    func rebuildArtistIndex() {
        creditKeyCache = [:]
        artistIndex = ArtistIndex(raw: rawArtists, rules: ArtistMergeStore.shared)
        artists = artistIndex.artists
    }

    /// The artists a credit names: itself, plus its parts when combined credits are split.
    func credits(of name: String?) -> [String] {
        guard let name, !name.isEmpty else { return [] }
        guard ArtistMergeStore.shared.splitCredits else { return [name] }
        let parts = ArtistMergeStore.creditParts(name) { self.artistIndex.artist(named: $0) != nil }
        return [name] + parts
    }

    /// Credit string → comparison keys of the artists it names. Pages ask for thousands of
    /// tracks at every redraw; the names repeat, so each is worked out once.
    private var creditKeyCache: [String: Set<String>] = [:]

    func creditKeys(of name: String?) -> Set<String> {
        guard let name, !name.isEmpty else { return [] }
        if let cached = creditKeyCache[name] { return cached }
        let keys = Set(credits(of: name).map(ArtistMergeStore.key))
        creditKeyCache[name] = keys
        return keys
    }

    /// Comparison keys of every server name behind an artist entry.
    private func memberKeys(of artist: ArtistItem) -> Set<String> {
        Set((artist.mergedNames ?? [artist.Name]).map(ArtistMergeStore.key))
    }

    /// Albums credited to the artist, under any of its merged names or inside a combined credit.
    func albums(byArtist artist: ArtistItem) -> [AlbumItem] {
        let keys = memberKeys(of: artist)
        return albums.filter { !creditKeys(of: $0.AlbumArtist).isDisjoint(with: keys) }
    }

    /// The album artist's photos, then the cover.
    func artistImageURLs(for album: AlbumItem, maxWidth: Int = 1600) -> [URL] {
        var urls = artist(named: album.AlbumArtist).map { artistImageURLs(for: $0, maxWidth: maxWidth) } ?? []
        if let cover = artworkURL(for: album.id, size: 800) {
            urls.append(cover)
        }
        return urls
    }

    /// Tracks where the artist is the album artist or one of the performers. Some files
    /// carry no artist tags at all, so tracks of the artist's albums count too.
    func tracks(byArtist artist: ArtistItem) -> [AudioItem] {
        let keys = memberKeys(of: artist)
        let albumIds = Set(albums(byArtist: artist).map(\.Id))
        func matches(_ name: String) -> Bool {
            !creditKeys(of: name).isDisjoint(with: keys)
        }
        return audioItems.filter { item in
            (item.AlbumArtists?.contains { matches($0.Name) } ?? false) ||
            (item.Artists?.contains(where: matches) ?? false) ||
            (item.AlbumId.map(albumIds.contains) ?? false)
        }
    }
    
    func toggleRepeatMode() {
        repeatMode.toggle()
        playerManager.repeatMode = repeatMode
    }
    
    /// Writes the current now-playing info to shared UserDefaults so the widget can read it.
    private func syncNowPlayingToWidget(item: AudioItem?, playing: Bool) {
        guard let item else {
            SharedDefaults.saveNowPlaying(nil)
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        
        let info = NowPlayingInfo(
            trackName: item.Name,
            artistName: item.mainArtistName ?? "Artista Sconosciuto",
            albumName: item.Album ?? "",
            albumId: item.AlbumId ?? item.id,
            trackId: item.id,
            isPlaying: playing,
            serverUrl: serverUrl,
            token: token,
            userId: userId
        )
        SharedDefaults.saveNowPlaying(info)
        WidgetCenter.shared.reloadAllTimelines()
    }

    
    // MARK: - Downloads

    func downloadTrack(_ item: AudioItem) {
        guard let url = apiService?.streamURL(for: item.Id) else { return }
        DownloadManager.shared.download(item: item, streamURL: url)
    }

    func removeDownload(for itemId: String) {
        DownloadManager.shared.removeDownload(for: itemId)
    }

    func isTrackDownloaded(_ itemId: String) -> Bool {
        DownloadManager.shared.isDownloaded(itemId)
    }

    /// Factory per creare un PlaylistViewModel con l'apiService corrente.
    /// Utile per creare istanze di PlaylistViewModel che condividono la stessa configurazione di rete.
    func makePlaylistViewModel() -> PlaylistViewModel {
        return PlaylistViewModel(apiService: apiService)
    }
    
    // MARK: - Private Setup and Storage
    
    /// Returns the current stream quality based on network type (cellular vs WiFi).
    func currentStreamQuality() -> StreamQuality {
        return isOnCellular ? streamQualityCellular : streamQualityWifi
    }
    
    private func setupAuthenticatedSession() {
        // (Ri)crea i servizi che dipendono dalle credenziali
        self.apiService = JellyfinAPIService(serverUrl: serverUrl, token: token, userId: userId)
        let api = apiService!
        // Settings backup on the server: restore on a fresh install, then keep it current.
        Task { await SettingsBackup.shared.connect(api: api) }
        let downloads = DownloadManager.shared
        self.playerManager = AudioPlayerManager(
            streamURLProvider: { [weak self] itemId in
                // Prefer local file if downloaded
                if let localURL = downloads.localURL(for: itemId) {
                    return localURL
                }
                // Check quality setting based on network type
                if let quality = self?.currentStreamQuality(), let bitrate = quality.bitrate {
                    return api.transcodedStreamURL(for: itemId, maxBitrate: bitrate)
                }
                return api.streamURL(for: itemId)
            },
            artworkURLProvider: api.artworkURL(for:size:)
        )
        // Autoplay's similar songs come from Jellyfin's Instant Mix.
        playerManager.similarProvider = { item in
            (try? await api.fetchInstantMix(itemId: item.Id)) ?? []
        }
        // Listens go to the server as real playback sessions (start, progress, stop).
        let reporter = PlaybackReporter(api: api, player: playerManager)
        playbackReporter = reporter
        playerManager.markPlayedProvider = { [weak self] itemId in
            // Shown at once, also when the server can't be reached; the server's list
            // replaces it once the report goes through.
            await MainActor.run { self?.noteRecentlyPlayed(itemId) }
            try await reporter.start(itemId: itemId)
        }
        playerManager.onDidReportPlayed = { [weak self] _ in
            Task { @MainActor in
                await self?.fetchRecentlyPlayedTracks()
            }
        }

        // Collega gli stati del Player Manager a quelli del ViewModel
        playerManager.$currentlyPlayingItem.assign(to: &$currentlyPlayingItem)
        playerManager.$isPlaying.assign(to: &$isPlaying)
        playerManager.$isPlaying.sink { [weak self] isPlaying in
            self?.onIsPlayingChanged?(isPlaying)
        }.store(in: &cancellables)
        playerManager.$currentTime.assign(to: &clock.$time)
        
        playerManager.repeatMode = repeatMode
        
        // Sync now-playing to widget whenever track or play state changes
        playerManager.$currentlyPlayingItem
            .combineLatest(playerManager.$isPlaying)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] (item, playing) in
                self?.syncNowPlayingToWidget(item: item, playing: playing)
            }
            .store(in: &cancellables)
    
        // Widgets: keep their snapshot current and let their buttons drive the player.
        // Last, because they observe the player created above.
        WidgetUpdater.shared.start(viewModel: self)
        PlaybackCommands.handler = { [weak self] command in
            guard let manager = self?.playerManager else { return }
            switch command {
            case .playPause: manager.togglePlayPause()
            case .next: manager.forward()
            case .previous: manager.backward()
            }
        }
    }

    private func saveCredentials() {
        UserDefaults.standard.set(token, forKey: StorageKeys.token)
        UserDefaults.standard.set(userId, forKey: StorageKeys.userId)
        UserDefaults.standard.set(serverUrl, forKey: StorageKeys.serverUrl)
    }

    private func loadCredentials() {
        let savedToken = UserDefaults.standard.string(forKey: StorageKeys.token) ?? ""
        let savedUserId = UserDefaults.standard.string(forKey: StorageKeys.userId) ?? ""
        let savedServer = UserDefaults.standard.string(forKey: StorageKeys.serverUrl) ?? ""
        self.serverUrl = savedServer
        if !serverUrl.isEmpty {
            self.apiService = JellyfinAPIService(serverUrl: serverUrl)
        } else {
            self.apiService = nil
        }
        
        // Carica preferiti salvati (se non fatto in init per qualche motivo)
        if self.favoriteAlbumIds.isEmpty, let saved = UserDefaults.standard.array(forKey: StorageKeys.favoriteAlbums) as? [String] {
            self.favoriteAlbumIds = Set(saved)
        }
        if self.favoriteTrackIds.isEmpty, let savedT = UserDefaults.standard.array(forKey: StorageKeys.favoriteTracks) as? [String] {
            self.favoriteTrackIds = Set(savedT)
        }
        if self.favoritePlaylistIds.isEmpty, let savedP = UserDefaults.standard.array(forKey: StorageKeys.favoritePlaylists) as? [String] {
            self.favoritePlaylistIds = Set(savedP)
        }
        
        if !savedToken.isEmpty && !savedUserId.isEmpty && !savedServer.isEmpty {
            self.token = savedToken
            self.userId = savedUserId
            self.isLoggedIn = true
        } else {
            self.isLoggedIn = false
        }
    }
    
    private func clearCredentials() {
        UserDefaults.standard.removeObject(forKey: StorageKeys.token)
        UserDefaults.standard.removeObject(forKey: StorageKeys.userId)
        // keep serverUrl so the user can login again without retyping; remove if you prefer otherwise
    }
}

/// The playback position on its own, so only the views that show it redraw.
final class PlaybackClock: ObservableObject {
    @Published var time: TimeInterval = 0
}
