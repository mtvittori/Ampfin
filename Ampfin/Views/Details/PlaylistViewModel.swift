//
//  PlaylistViewModel.swift
//  Ampfin
//
//  Created by Marco Vittori on 28/08/25.
//


// PlaylistViewModel.swift
import Foundation

@MainActor
class PlaylistViewModel: ObservableObject {
    @Published private(set) var playlists: [PlaylistItem] = []
    @Published private(set) var isLoading: Bool = false
    @Published var errorMessage: String?

    // L'apiService è opzionale così possiamo inizializzarlo prima senza avere subito l'API (utile in SwiftUI)
    var apiService: JellyfinAPIService?

    init(apiService: JellyfinAPIService?) {
        self.apiService = apiService
    }
 
    func setAPIService(_ service: JellyfinAPIService?) {
        self.apiService = service
    }

    /// Recupera le playlist dell'utente
    func fetchPlaylists() async {
        guard let api = apiService else {
            self.errorMessage = "Server non configurato."
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let items = try await api.fetchUserPlaylists()
            self.playlists = items
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    /// Recupera gli elementi (AudioItem) della playlist specificata
    func fetchPlaylistItems(playlistId: String) async throws -> [AudioItem] {
        guard let api = apiService else {
            throw APIError.invalidURL
        }
        return try await api.fetchPlaylistItems(playlistId: playlistId)
    }

    /// Helper per ottenere l'URL dell'artwork
    func artworkURL(for itemId: String, size: Int = 200) -> URL? {
        return apiService?.artworkURL(for: itemId, size: size)
    }
}
