// In ViewModels/JellyfinViewModel.swift
import Foundation
import Combine

@MainActor // Garantisce che tutte le modifiche alle property @Published avvenga sul Main Thread
class JellyfinViewModel: ObservableObject {
    // MARK: - Published Properties (Stato dell'UI)
    @Published private(set) var audioItems: [AudioItem] = []
    @Published private(set) var albums: [AlbumItem] = []
    @Published private(set) var artists: [ArtistItem] = []
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
    @Published private(set) var currentTime: TimeInterval = 0

    @Published private(set) var recentlyPlayedAlbums: [AlbumItem] = []
    @Published private(set) var recentlyAddedAlbums: [AlbumItem] = [] // cached recently added albums

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

    // MARK: - Servizi e Manager
    private var apiService: JellyfinAPIService?
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
    }
    
    private var token: String = ""
    private var userId: String = ""
    
    private var cancellables = Set<AnyCancellable>()
    private var serverUrlCancellable: AnyCancellable?

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
        
        // Configuriamo un debounce sul serverUrl: persiste subito, ma (ri)crea apiService solo dopo pausa di digitazione
        serverUrlCancellable = $serverUrl
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] newValue in
                Task { @MainActor in
                    self?.createApiServiceIfNeeded(from: newValue)
                }
            }
        
        // Carica le credenziali e, se presenti e se abbiamo una serverUrl, avvia il setup
        loadCredentials()
        if !token.isEmpty && !userId.isEmpty && !serverUrl.isEmpty {
            setupAuthenticatedSession()
            self.isLoggedIn = true
        }
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
    func testServerConnection(serverURL: String? = nil) async -> Bool {
        isTestingConnection = true
        errorMessage = nil
        lastConnectionTestResult = nil
        
        let base = (serverURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? serverUrl)
        guard !base.isEmpty, let url = URL(string: "\(base)/System/Info/Public") else {
            self.errorMessage = "URL non valida."
            isTestingConnection = false
            lastConnectionTestResult = false
            return false
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                isTestingConnection = false
                lastConnectionTestResult = true
                return true
            } else {
                self.errorMessage = "Server non raggiungibile (status: \((response as? HTTPURLResponse)?.statusCode ?? 0))."
                isTestingConnection = false
                lastConnectionTestResult = false
                return false
            }
        } catch {
            self.errorMessage = "Errore di connessione: \(error.localizedDescription)"
            isTestingConnection = false
            lastConnectionTestResult = false
            return false
        }
    }
    
    // MARK: - Authentication
    
    /// Effettua il login verso Jellyfin. Se `serverURL` è fornita, la usa per inizializzare il servizio prima del login.
    func login(username: String, password: String, serverURL: String? = nil) async {
        isLoading = true
        errorMessage = nil
        
        // Se l'utente ha fornito una URL, aggiorna la serverUrl e ricrea apiService (immediato per il login)
        if let provided = serverURL?.trimmingCharacters(in: .whitespacesAndNewlines), !provided.isEmpty {
            self.serverUrl = provided
            self.apiService = JellyfinAPIService(serverUrl: provided)
            // Persistiamo la serverUrl
            UserDefaults.standard.set(provided, forKey: StorageKeys.serverUrl)
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
        audioItems = []
        albums = []
        artists = []
        allAvailableGenres = []
        selectedAlbumTracks = []
        currentlyPlayingItem = nil
        isPlaying = false
        currentTime = 0
        recentlyPlayedAlbums = []
        recentlyAddedAlbums = []
        
        // Credenziali e flags
        token = ""
        userId = ""
        isLoggedIn = false
        errorMessage = nil
        
        // Rimuovi dal persistent storage (ma mantieni la serverUrl)
        clearCredentials()
        
        // Ricrea il servizio API senza credenziali (ma con la stessa serverUrl pronta per un nuovo login)
        if !serverUrl.isEmpty {
            self.apiService = JellyfinAPIService(serverUrl: serverUrl)
        } else {
            self.apiService = nil
        }
    }
    
    // MARK: - Fetch helpers (ora controllano che apiService sia disponibile)
    func fetchRecentlyPlayedAlbums() async {
        guard let api = apiService else {
            self.errorMessage = "Server URL non impostata."
            return
        }
        do {
            let albums = try await api.fetchRecentlyPlayedAlbums()
            self.recentlyPlayedAlbums = albums
        } catch {
            self.errorMessage = error.localizedDescription
        }
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
        guard isLoggedIn else { return }
        if !force && !recentlyPlayedAlbums.isEmpty {
            return
        }
        await fetchRecentlyPlayedAlbums()
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
            self.albums = fetchedAlbums.sorted { a, b in
                let aDate = a.dateAddedDate ?? Date.distantPast
                let bDate = b.dateAddedDate ?? Date.distantPast
                return aDate > bDate
            }
            self.artists = fetchedArtists
            self.allAvailableGenres = Array(Set(fetchedTracks.compactMap { $0.Genres }.flatMap { $0 })).sorted()
            
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

    // MARK: - Public Helper Methods
    
    func artworkURL(for itemId: String, size: Int = 200) -> URL? {
        return apiService?.artworkURL(for: itemId, size: size)
    }
    
    func streamURL(for itemId: String) -> URL? {
        return apiService?.streamURL(for: itemId)
    }
    
    func toggleRepeatMode() {
        repeatMode.toggle()
        playerManager.repeatMode = repeatMode
    }
    
    /// Factory per creare un PlaylistViewModel con l'apiService corrente.
    /// Utile per creare istanze di PlaylistViewModel che condividono la stessa configurazione di rete.
    func makePlaylistViewModel() -> PlaylistViewModel {
        return PlaylistViewModel(apiService: apiService)
    }
    
    // MARK: - Private Setup and Storage
    
    private func setupAuthenticatedSession() {
        // (Ri)crea i servizi che dipendono dalle credenziali
        self.apiService = JellyfinAPIService(serverUrl: serverUrl, token: token, userId: userId)
        self.playerManager = AudioPlayerManager(streamURLProvider: apiService!.streamURL(for:))
        
        // Collega gli stati del Player Manager a quelli del ViewModel
        playerManager.$currentlyPlayingItem.assign(to: &$currentlyPlayingItem)
        playerManager.$isPlaying.assign(to: &$isPlaying)
        playerManager.$isPlaying.sink { [weak self] isPlaying in
            self?.onIsPlayingChanged?(isPlaying)
        }.store(in: &cancellables)
        playerManager.$currentTime.assign(to: &$currentTime)
        
        playerManager.repeatMode = repeatMode
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
