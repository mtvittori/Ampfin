import Foundation
import Combine

@MainActor // Garantisce che tutte le modifiche alle property @Published avvengano sul Main Thread
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
    
    // MARK: - Player State (inoltrato dal Player Manager)
    @Published private(set) var currentlyPlayingItem: AudioItem?
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: TimeInterval = 0
    
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
        // Inizializza il servizio API con un URL base
        self.apiService = JellyfinAPIService(serverUrl: serverUrl)
        
        // Carica le credenziali e, se presenti, avvia il setup
        loadCredentials()
               if isLoggedIn {
            setupAuthenticatedSession()
        }
    }
    
    // MARK: - Authentication Logic
    
    func login(username: String, password: String) async {
        isLoading = true
        errorMessage = nil
        
        do {
            let response = try await apiService.login(username: username, password: password)
            self.token = response.AccessToken
            self.userId = response.User.Id
            saveCredentials()
            self.isLoggedIn = true
            setupAuthenticatedSession()
            await fetchAllLibraryData()
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "Errore sconosciuto."
        }
        isLoading = false
    }

    func logout() {
        playerManager.stop()
        clearCredentials()
        isLoggedIn = false
        // Resetta tutti i dati
        audioItems = []; albums = []; artists = []; allAvailableGenres = []
        cancellables.removeAll() // Rimuove gli observer del player
    }

    // MARK: - Data Fetching Logic
    
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
    
    // MARK: - Private Setup and Storage
    
    private func setupAuthenticatedSession() {
        // (Ri)crea i servizi che dipendono dalle credenziali
        self.apiService = JellyfinAPIService(serverUrl: serverUrl, token: token, userId: userId)
        self.playerManager = AudioPlayerManager(streamURLProvider: apiService.streamURL(for:))
        
        // Collega gli stati del Player Manager a quelli del ViewModel
        playerManager.$currentlyPlayingItem.assign(to: &$currentlyPlayingItem)
        playerManager.$isPlaying.assign(to: &$isPlaying)
        playerManager.$currentTime.assign(to: &$currentTime)
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
