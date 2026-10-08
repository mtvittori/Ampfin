// MixStore.swift
// The user's playlists on Jellyfin and the recommended mixes for the Home: Ampfin's own
// (MixEngine, from this user's listening) or the ones server plugins make, as chosen in
// Settings → Mix consigliati. Also adding songs to playlists and making new ones.

import SwiftUI

/// Where the Home's recommended mixes come from (Settings → Mix consigliati).
enum MixSource: String, CaseIterable, Identifiable {
    case ampfin, jellyfin

    static let storageKey = "mixSource"
    /// Whether two of the mixes also appear among the top picks (Settings → Mix in Home).
    static let topPicksKey = "mixesInTopPicks"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ampfin: return "Ampfin"
        case .jellyfin: return "Jellyfin"
        }
    }
}

@MainActor
final class MixStore: ObservableObject {
    static let shared = MixStore()

    @Published private(set) var mixes: [Mix] = []
    @Published private(set) var playlists: [PlaylistItem] = []
    @Published private(set) var playlistsLoaded = false
    /// Songs waiting for the name of a new playlist (the "Nuova playlist…" prompt).
    @Published var pendingNewPlaylist: [AudioItem]?

    /// The user and day the mixes were made for: they're made again for another of either.
    private var mixesKey: String?
    private var historyFetched: Date?

    /// Playlists made by people (the user's and those shared with them).
    var userPlaylists: [PlaylistItem] {
        playlists.filter { !$0.isAlbumFile && !$0.isServerMix }
    }

    /// Playlists made by server plugins (AudioMuse-AI, Playlist Generator).
    var serverMixes: [PlaylistItem] {
        playlists.filter(\.isServerMix)
    }

    // MARK: - Loading

    func refreshPlaylists(viewModel: JellyfinViewModel) async {
        guard let api = viewModel.apiService else { return }
        if let items = try? await api.fetchUserPlaylists() {
            playlists = items
        }
        playlistsLoaded = true
    }

    /// Makes the mixes again when the user, the day or the library changed, or the history
    /// is older than ten minutes.
    func refreshMixes(viewModel: JellyfinViewModel, force: Bool = false) async {
        guard let api = viewModel.apiService, !viewModel.audioItems.isEmpty else { return }
        let day = Date().formatted(.iso8601.year().month().day())
        let key = "\(viewModel.currentUserId)|\(day)|\(viewModel.audioItems.count)"
        let stale = historyFetched.map { Date().timeIntervalSince($0) > 600 } ?? true
        guard force || key != mixesKey || stale else { return }

        guard let history = try? await api.fetchListeningHistory() else { return }
        historyFetched = Date()

        let library = viewModel.audioItems
        var artistNames: [String: String] = [:]
        for item in library + history {
            artistNames[item.Id] = viewModel.artistName(for: item) ?? ""
        }
        let input = MixEngine.Input(
            library: library, history: history,
            favoriteTrackIds: Set(viewModel.favoriteTracks.map(\.Id)),
            recentAlbumIds: viewModel.recentlyAddedAlbums.map(\.Id),
            artistNames: artistNames, userKey: viewModel.currentUserId, day: day
        )
        // Thousands of songs: worked out away from the main thread.
        let made = await Task.detached(priority: .utility) { MixEngine.mixes(input) }.value
        mixes = made
        mixesKey = key
    }

    /// After logging out, nothing of the previous user stays.
    func reset() {
        mixes = []
        playlists = []
        playlistsLoaded = false
        mixesKey = nil
        historyFetched = nil
    }

    // MARK: - Editing playlists

    func add(_ tracks: [AudioItem], to playlist: PlaylistItem, viewModel: JellyfinViewModel) {
        guard let api = viewModel.apiService, !tracks.isEmpty else { return }
        Task {
            do {
                try await api.addToPlaylist(playlistId: playlist.Id, itemIds: tracks.map(\.Id))
                QueueFeedback.shared.show("Aggiunto a \(playlist.Name)", systemImage: "music.note.list")
                await refreshPlaylists(viewModel: viewModel)
            } catch {
                QueueFeedback.shared.show("Playlist non aggiornata", systemImage: "exclamationmark.triangle")
            }
        }
    }

    func createPlaylist(named name: String, with tracks: [AudioItem], viewModel: JellyfinViewModel) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api = viewModel.apiService, !name.isEmpty else { return }
        Task {
            do {
                try await api.createPlaylist(name: name, itemIds: tracks.map(\.Id))
                QueueFeedback.shared.show("Playlist \"\(name)\" creata", systemImage: "music.note.list")
                await refreshPlaylists(viewModel: viewModel)
            } catch {
                QueueFeedback.shared.show("Playlist non creata", systemImage: "exclamationmark.triangle")
            }
        }
    }

    func remove(_ track: AudioItem, from playlist: PlaylistItem, viewModel: JellyfinViewModel) async -> Bool {
        guard let api = viewModel.apiService, let entry = track.PlaylistItemId else { return false }
        do {
            try await api.removeFromPlaylist(playlistId: playlist.Id, entryIds: [entry])
            await refreshPlaylists(viewModel: viewModel)
            return true
        } catch {
            QueueFeedback.shared.show("Brano non rimosso", systemImage: "exclamationmark.triangle")
            return false
        }
    }

    func delete(_ playlist: PlaylistItem, viewModel: JellyfinViewModel) async {
        guard let api = viewModel.apiService else { return }
        do {
            try await api.deletePlaylist(playlistId: playlist.Id)
            playlists.removeAll { $0.Id == playlist.Id }
            QueueFeedback.shared.show("Playlist eliminata", systemImage: "trash")
        } catch {
            QueueFeedback.shared.show("Playlist non eliminata", systemImage: "exclamationmark.triangle")
        }
    }
}

// MARK: - Menu

/// "Aggiungi a playlist" for a song's (or a mix's) menu: the user's playlists, and a new one.
struct AddToPlaylistMenu: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var store = MixStore.shared
    let tracks: [AudioItem]

    var body: some View {
        Menu {
            Button {
                store.pendingNewPlaylist = tracks
            } label: {
                Label("Nuova playlist…", systemImage: "plus")
            }
            if !store.userPlaylists.isEmpty {
                Divider()
                ForEach(store.userPlaylists) { playlist in
                    Button(playlist.Name) {
                        store.add(tracks, to: playlist, viewModel: viewModel)
                    }
                }
            }
        } label: {
            Label("Aggiungi a playlist", systemImage: "text.badge.plus")
        }
    }
}

/// The name prompt for "Nuova playlist…", shown over the whole app.
struct NewPlaylistPrompt: ViewModifier {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var store = MixStore.shared
    @State private var name = ""

    func body(content: Content) -> some View {
        content.alert("Nuova playlist", isPresented: Binding(
            get: { store.pendingNewPlaylist != nil },
            set: { if !$0 { store.pendingNewPlaylist = nil } }
        )) {
            TextField("Nome", text: $name)
            Button("Annulla", role: .cancel) { name = "" }
            Button("Crea") {
                store.createPlaylist(named: name, with: store.pendingNewPlaylist ?? [], viewModel: viewModel)
                name = ""
            }
        } message: {
            let count = store.pendingNewPlaylist?.count ?? 0
            Text(count == 0 ? "Una playlist vuota su Jellyfin."
                 : count == 1 ? "Con il brano scelto." : "Con \(count) brani.")
        }
    }
}
