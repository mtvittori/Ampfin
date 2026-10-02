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

class JellyfinAPIService {
    
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
        
        let authHeader = "MediaBrowser Client=\"Ampfin\", Device=\"macOS\", DeviceId=\"\(JellyfinAPIService.deviceId)\", Version=\"1.0.0\""
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        
        struct LoginRequest: Codable { let Username: String; let Pw: String }
        request.httpBody = try JSONEncoder().encode(LoginRequest(Username: username, Pw: password))

        let (data, response) = try await URLSession.shared.data(for: request)
        
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
    
    /// Fetches recently played albums for the current user
    func fetchRecentlyPlayedAlbums() async throws -> [AlbumItem] {
        // Step 1: Fetch the user's music library id
        let libraryId = try await fetchMusicLibraryId()
        // Step 2: Fetch recently played albums only within the music library
        let endpoint = "/Users/\(userId)/Items?ParentId=\(libraryId)&IncludeItemTypes=MusicAlbum&SortBy=DatePlayed&SortOrder=Descending&Limit=20"
        let response: AlbumResponse = try await fetch(endpoint: endpoint)
        return response.Items
    }
    
    /// Fetches recently added albums (ordered by DateAdded descending).
    /// Named as requested: fetchRecentAddedAlbums()
    func fetchRecentAddedAlbums() async throws -> [AlbumItem] {
        let libraryId = try await fetchMusicLibraryId()
        // Use DateAdded to reflect actual time the item was added to the library
        let endpoint = "/Users/\(userId)/Items?ParentId=\(libraryId)&IncludeItemTypes=MusicAlbum&Recursive=true&SortBy=DateAdded&SortOrder=Descending&Limit=20"
        let response: AlbumResponse = try await fetch(endpoint: endpoint)
        return response.Items
    }

    func fetchMusicLibraryId() async throws -> String {
        let response: UserViewsResponse = try await fetch(endpoint: "/Users/\(userId)/Views")
        if let musicLibrary = response.Items.first(where: { $0.CollectionType == "music" }) {
            return musicLibrary.Id
        } else {
            throw APIError.invalidResponse(404) // Simula un "not found"
        }
    }
    
    func fetchTracks(from libraryId: String) async throws -> [AudioItem] {
        let endpoint = "/Users/\(userId)/Items?ParentId=\(libraryId)&IncludeItemTypes=Audio&Recursive=true&Fields=AlbumArtists,Artists,MediaSources,AlbumId,Genres&SortBy=SortName"
        let response: AudioResponse = try await fetch(endpoint: endpoint)
        return response.Items
    }
    
    func fetchAlbums(from libraryId: String) async throws -> [AlbumItem] {
        // Modificato: ordina per DateAdded in ordine discendente così gli album saranno mostrati per data di aggiunta
        let endpoint = "/Users/\(userId)/Items?ParentId=\(libraryId)&IncludeItemTypes=MusicAlbum&Recursive=true&Fields=ProductionYear,AlbumArtists&SortBy=DateAdded&SortOrder=Descending"
        let response: AlbumResponse = try await fetch(endpoint: endpoint)
        return response.Items
    }
    
    func fetchArtists(from libraryId: String) async throws -> [ArtistItem] {
        let endpoint = "/Users/\(userId)/Items?ParentId=\(libraryId)&IncludeItemTypes=MusicArtist&Recursive=true&SortBy=SortName"
        let response: ArtistResponse = try await fetch(endpoint: endpoint)
        return response.Items
    }

    func fetchAlbumTracks(albumId: String) async throws -> [AudioItem] {
        let endpoint = "/Users/\(userId)/Items?ParentId=\(albumId)&SortBy=SortName&SortOrder=Ascending&IncludeItemTypes=Audio&Fields=AlbumArtists,Artists,MediaSources,AlbumId"
        let response: AudioResponse = try await fetch(endpoint: endpoint)
        return response.Items
    }

    // MARK: - Playlists API (nuovi metodi)
    /// Recupera le playlist dell'utente
    func fetchUserPlaylists() async throws -> [PlaylistItem] {
        // Endpoint: chiediamo Items con IncludeItemTypes=Playlist; Jellyfin ritorna le playlist come Items
        let endpoint = "/Users/\(userId)/Items?IncludeItemTypes=Playlist&Recursive=true&SortBy=Name"
        let response: PlaylistResponse = try await fetch(endpoint: endpoint)
        return response.Items
    }

    /// Recupera gli elementi di una playlist specifica
    /// Nota: l'endpoint /Playlists/{id}/Items ritorna gli items della playlist
    func fetchPlaylistItems(playlistId: String) async throws -> [AudioItem] {
        let endpoint = "/Playlists/\(playlistId)/Items"
        let response: AudioResponse = try await fetch(endpoint: endpoint)
        return response.Items
    }
    
    // MARK: - URL Helpers
    
    func artworkURL(for itemId: String, size: Int = 200) -> URL? {
        return URL(string: "\(serverUrl)/Items/\(itemId)/Images/Primary?maxHeight=\(size)&maxWidth=\(size)&quality=90&tag=&api_key=\(token)")
    }
    
    func streamURL(for itemId: String) -> URL? {
        return URL(string: "\(serverUrl)/Audio/\(itemId)/stream?static=true&api_key=\(token)")
    }

    // MARK: - Generic Fetch Helper
    
    private func fetch<T: Codable>(endpoint: String) async throws -> T {
        guard let url = URL(string: "\(serverUrl)\(endpoint)") else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        addAuthHeader(to: &request)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
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
    
    private func addAuthHeader(to request: inout URLRequest) {
        let authHeader = "MediaBrowser Client=\"Ampfin\", Device=\"macOS\", DeviceId=\"\(JellyfinAPIService.deviceId)\", Version=\"1.0.0\", Token=\"\(token)\""
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
}
