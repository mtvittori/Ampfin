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
    
    // MARK: - Servizi e Manager
    private var apiService: JellyfinAPIService
    private(set) var playerManager: AudioPlayerManager!
    
    // MARK: - Credenziali e Storage
    private var token: String = ""
    private var userId: String = ""
    private let serverUrl: String = "http://192.168.0.106:8096" // Potrebbe essere configurabile
    private enum StorageKeys {
        static let token = "jellyfin_accesstoken"
        static let userId = "jellyfin_userid"
    }
    
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init
    init() {
        // Inizializza il servizio API con un URL base (senza credenziali)
        self.apiService = JellyfinAPIService(serverUrl: serverUrl)
        
        // Carica le credenziali e, se presenti, avvia il setup
        loadCredentials()
        if isLoggedIn {
            setupAuthenticatedSession()
        }
    }
    
    // MARK: - Authentication
    
    /// Effettua il login verso Jellyfin. Aggiorna token/userId, salva credenziali e crea i manager autenticati.
    func login(username: String, password: String) async {
        isLoading = true
        errorMessage = nil
        do {
            // usa il servizio API corrente (inizializzato senza token)
            let response = try await apiService.login(username: username, password: password)
            
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
        
        // Rimuovi dal persistent storage
        clearCredentials()
        
        // Ricrea il servizio API senza credenziali (per eventuali nuove login)
        self.apiService = JellyfinAPIService(serverUrl: serverUrl)
    }
    
    // MARK: - Fetch helpers (unchanged)
    func fetchRecentlyPlayedAlbums() async {
        do {
            let albums = try await apiService.fetchRecentlyPlayedAlbums()
            self.recentlyPlayedAlbums = albums
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
    
    // NEW: fetch recently added albums (no caching here; caching applied in the "ifNeeded" wrapper)
    func fetchRecentAddedAlbums() async {
        guard isLoggedIn else { return }
        do {
            let albums = try await apiService.fetchRecentAddedAlbums()
            self.recentlyAddedAlbums = albums
            self.recentlyAddedAlbumsFetchDate = Date()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
    
    // Public helper that checks cache TTL before fetching
    func fetchRecentlyAddedAlbumsIfNeeded(force: Bool = false) async {
        guard isLoggedIn else { return }
        if !force,
           let fetchedAt = recentlyAddedAlbumsFetchDate,
           !recentlyAddedAlbums.isEmpty,
           Date().timeIntervalSince(fetchedAt) < recentlyAddedAlbumsCacheTTL {
            // cache still valid - do nothing
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
        guard isLoggedIn else { return }
        isLoading = true
        
        do {
            let libraryId = try await apiService.fetchMusicLibraryId()
            
            // Esegui le chiamate in parallelo per velocizzare
            async let tracks = apiService.fetchTracks(from: libraryId)
            async let albums = apiService.fetchAlbums(from: libraryId)
            async let artists = apiService.fetchArtists(from: libraryId)
            
            let (fetchedTracks, fetchedAlbums, fetchedArtists) = try await (tracks, albums, artists)
            
            self.audioItems = fetchedTracks
            self.albums = fetchedAlbums
            self.artists = fetchedArtists
            self.allAvailableGenres = Array(Set(fetchedTracks.compactMap { $0.Genres }.flatMap { $0 })).sorted()
            
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "Errore nel caricamento della libreria."
        }
        isLoading = false
    }
    
    func fetchAlbumTracks(albumId: String) async {
        isLoadingAlbum = true
        selectedAlbumTracks = []
        do {
            self.selectedAlbumTracks = try await apiService.fetchAlbumTracks(albumId: albumId)
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "Errore nel caricamento delle tracce dell'album."
        }
        isLoadingAlbum = false
    }

    // MARK: - Public Helper Methods
    
    func artworkURL(for itemId: String, size: Int = 200) -> URL? {
        return apiService.artworkURL(for: itemId, size: size)
    }
    
    func toggleRepeatMode() {
        repeatMode.toggle()
        playerManager.repeatMode = repeatMode
    }
    
    // MARK: - Private Setup and Storage
    
    private func setupAuthenticatedSession() {
        // (Ri)crea i servizi che dipendono dalle credenziali
        self.apiService = JellyfinAPIService(serverUrl: serverUrl, token: token, userId: userId)
        self.playerManager = AudioPlayerManager(streamURLProvider: apiService.streamURL(for:))
        
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
    }

    private func loadCredentials() {
        let savedToken = UserDefaults.standard.string(forKey: StorageKeys.token) ?? ""
        let savedUserId = UserDefaults.standard.string(forKey: StorageKeys.userId) ?? ""
        
        if !savedToken.isEmpty && !savedUserId.isEmpty {
            self.token = savedToken
            self.userId = savedUserId
            self.isLoggedIn = true
        }
    }
    
    private func clearCredentials() {
        UserDefaults.standard.removeObject(forKey: StorageKeys.token)
        UserDefaults.standard.removeObject(forKey: StorageKeys.userId)
    }
}
