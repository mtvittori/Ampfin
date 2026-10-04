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
    @State private var showSidePanel = false
    @State private var path = NavigationPath()
    @AppStorage("macSidePanelTab") private var panelTab = MacSidePanel.Tab.queue.rawValue

    private let library: [MacSection] = [.recent, .artists, .albums, .tracks, .genres, .favorites]

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            NavigationStack(path: $path) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationDestination(for: AlbumItem.self) { AlbumTracksListView(album: $0) }
                    .navigationDestination(for: ArtistItem.self) { ArtistAlbumsView(artist: $0) }
                    .navigationDestination(for: String.self) { MacGenrePage(genreName: $0) }
            }
            // Choosing another section starts from its own page again.
            .id(selection ?? .home)
            // Pages scroll under the playback bar, with room to see their last row.
            .contentMargins(.bottom, 96, for: .scrollContent)
            .overlay(alignment: .bottom) {
                MacPlaybackBar(player: viewModel.playerManager, showPanel: $showSidePanel, panelTab: $panelTab)
                    .frame(maxWidth: 720)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)
            }
            .toolbar(removing: .title)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .inspector(isPresented: $showSidePanel) {
            MacSidePanel(tab: $panelTab)
                .inspectorColumnWidth(min: 280, ideal: 330, max: 440)
        }
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
                panelTab = panel == "lyrics" ? MacSidePanel.Tab.lyrics.rawValue : MacSidePanel.Tab.queue.rawValue
                showSidePanel = true
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
