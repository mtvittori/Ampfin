// MacShell.swift
// The Mac window, laid out like Music: a sidebar (Search, Home, then the Library and the
// Playlists, your profile at the bottom), the pages with their big titles, no toolbar, and
// the playback bar floating at the bottom of the window. Queue and lyrics open in a panel
// on the right.

#if os(macOS)
import SwiftUI

/// What the sidebar can show.
enum MacSection: String, Identifiable {
    case search, home, recent, artists, albums, tracks, genres, favorites, playlists

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: return "Cerca"
        case .home: return "Home"
        case .recent: return "Aggiunti di recente"
        case .artists: return "Artisti"
        case .albums: return "Album"
        case .tracks: return "Brani"
        case .genres: return "Generi"
        case .favorites: return "Preferiti"
        case .playlists: return "Playlist"
        }
    }

    var systemImage: String {
        switch self {
        case .search: return "magnifyingglass"
        case .home: return "house"
        case .recent: return "clock"
        case .artists: return "music.mic"
        case .albums: return "square.stack"
        case .tracks: return "music.note"
        case .genres: return "guitars"
        case .favorites: return "heart"
        case .playlists: return "music.note.list"
        }
    }
}

struct MacShell: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    @State private var selection: MacSection? = .home
    @State private var path = NavigationPath()
    @State private var playerState = MacPlayerState()

    private let library: [MacSection] = [.recent, .artists, .albums, .tracks, .genres, .favorites]

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            NavigationStack(path: $path) {
                // Every page, the pushed ones too, carries the playback bar and the clear toolbar.
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .macPageChrome()
                    .navigationDestination(for: AlbumItem.self) { AlbumTracksListView(album: $0).macPageChrome() }
                    .navigationDestination(for: ArtistItem.self) { ArtistAlbumsView(artist: $0).macPageChrome() }
                    .navigationDestination(for: String.self) { MacGenrePage(genreName: $0).macPageChrome() }
            }
            // Choosing another section starts from its own page again.
            .id(selection ?? .home)
        }
        .toolbarVisibility(playerState.showFullPlayer ? .hidden : .automatic, for: .windowToolbar)
        .inspector(isPresented: $playerState.showPanel) {
            MacSidePanel(tab: $playerState.panelTab)
                .inspectorColumnWidth(min: 280, ideal: 330, max: 440)
        }
        // Now Playing takes the whole window, as Music's full-screen player. It sits over
        // the split view, which is hidden meanwhile: pages pushed on the navigation stack
        // are drawn by AppKit above anything placed inside it, so they'd show through.
        .opacity(playerState.showFullPlayer ? 0 : 1)
        .allowsHitTesting(!playerState.showFullPlayer)
        .overlay {
            if playerState.showFullPlayer {
                MacFullPlayer(player: viewModel.playerManager)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: playerState.showFullPlayer)
        .onChange(of: viewModel.currentlyPlayingItem == nil) { _, stopped in
            if stopped { playerState.showFullPlayer = false }
        }
        .onChange(of: selection) { playerState.minimized = false }
        .environment(playerState)
        .frame(minWidth: 900, minHeight: 600)
        #if DEBUG
        .task {
            // Test-only: `-provaScheda artists` opens that section, `-provaPannello queue|lyrics` the panel.
            let defaults = UserDefaults.standard
            try? await Task.sleep(for: .seconds(2))
            if let tab = defaults.string(forKey: "provaScheda").flatMap(MacSection.init(rawValue:)) { selection = tab }
            // `-provaAlbum <name>` / `-provaArtista <name>` open that page.
            for _ in 0..<40 where viewModel.albums.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            if let name = defaults.string(forKey: "provaAlbum"),
               let album = viewModel.albums.first(where: { $0.Name.localizedCaseInsensitiveContains(name) }) {
                path.append(album)
            } else if let name = defaults.string(forKey: "provaArtista"),
                      let artist = viewModel.artists.first(where: { $0.Name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                path.append(artist)
            }
            if let query = defaults.string(forKey: "provaCerca") {
                selection = .search
                viewModel.globalSearchQuery = query
            }
            if let panel = defaults.string(forKey: "provaPannello") {
                playerState.panelTab = panel == "lyrics" ? MacSidePanel.Tab.lyrics.rawValue : MacSidePanel.Tab.queue.rawValue
                playerState.showPanel = true
            }
            // `-provaPlay <artist>` starts that artist muted and pauses at once, so the bar
            // and the player have something to show without a sound; `-provaFull YES` opens it.
            if let name = defaults.string(forKey: "provaPlay"),
               let artist = viewModel.artists.first(where: { $0.Name.localizedCaseInsensitiveCompare(name) == .orderedSame }),
               let first = viewModel.tracks(byArtist: artist).first {
                let player = viewModel.playerManager!
                let volume = player.volume
                player.volume = 0
                player.play(item: first, in: viewModel.tracks(byArtist: artist))
                for _ in 0..<60 where viewModel.currentTime <= 0 { try? await Task.sleep(for: .milliseconds(250)) }
                player.pause()
                player.volume = volume
                if defaults.bool(forKey: "provaFull") { playerState.showFullPlayer = true }
            }
            if defaults.bool(forKey: "provaMini") {
                try? await Task.sleep(for: .seconds(1))
                playerState.minimized = true
            }
        }
        #endif
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Label(MacSection.search.title, systemImage: MacSection.search.systemImage).tag(MacSection.search)
            Label(MacSection.home.title, systemImage: MacSection.home.systemImage).tag(MacSection.home)

            Section("Libreria") {
                ForEach(library) { item in
                    Label(item.title, systemImage: item.systemImage).tag(item)
                }
            }

            Section("Playlist") {
                Label(MacSection.playlists.title, systemImage: MacSection.playlists.systemImage).tag(MacSection.playlists)
            }
        }
        .listStyle(.sidebar)
        // Your profile at the bottom, as in Music; it opens the Settings window.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SettingsLink {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text(NSFullUserName())
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "gearshape").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Impostazioni")
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .home {
        case .search: MacSearchPage()
        case .home: MacHomeView()
        case .recent: MacRecentView()
        case .albums: MacAlbumsView()
        case .artists: MacArtistsView()
        case .tracks: MacTracksView()
        case .genres: MacGenresView()
        case .favorites: MacFavoritesView()
        case .playlists: MacPlaylistsView()
        }
    }
}
#endif
