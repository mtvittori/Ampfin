// MacShell.swift
// The Mac window, laid out like Music: a sidebar with the search field on top and the
// library under it, transport controls and the "now playing" lozenge in the toolbar,
// and the queue / lyrics in a panel on the right.

#if os(macOS)
import SwiftUI

struct MacShell: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    typealias Section = ContentView.SidebarItem

    @State private var selection: Section? = .home
    @State private var showSidePanel = false
    @State private var path = NavigationPath()
    @AppStorage("macSidePanelTab") private var panelTab = MacSidePanel.Tab.queue.rawValue

    private let library: [Section] = [.albums, .artists, .tracks, .genres, .favorites]

    private var isSearching: Bool {
        !viewModel.globalSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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
            .id(isSearching ? Section.search : (selection ?? .home))
            // Music's toolbar: transport on the left, the now-playing lozenge in the middle,
            // lyrics and queue on the right, then the search field.
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    MacTransportControls(player: viewModel.playerManager)
                }
                ToolbarItem(placement: .principal) {
                    MacNowPlayingBar()
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItemGroup(placement: .primaryAction) {
                    panelButton(.lyrics, systemImage: "quote.bubble", help: "Testi")
                    panelButton(.queue, systemImage: "list.bullet", help: "Coda")
                }
            }
        }
        .searchable(text: $viewModel.globalSearchQuery, placement: .toolbar, prompt: "Cerca")
        .toolbar(removing: .title)
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
            if let tab = defaults.string(forKey: "provaScheda").flatMap(Section.init(rawValue:)) { selection = tab }
            // `-provaAlbum <name>` / `-provaArtista <name>` open that page.
            for _ in 0..<40 where viewModel.albums.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            if let name = defaults.string(forKey: "provaAlbum"),
               let album = viewModel.albums.first(where: { $0.Name.localizedCaseInsensitiveContains(name) }) {
                path.append(album)
            } else if let name = defaults.string(forKey: "provaArtista"),
                      let artist = viewModel.artists.first(where: { $0.Name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                path.append(artist)
            }
            if let query = defaults.string(forKey: "provaCerca") { viewModel.globalSearchQuery = query }
            if let panel = defaults.string(forKey: "provaPannello") {
                panelTab = panel == "lyrics" ? MacSidePanel.Tab.lyrics.rawValue : MacSidePanel.Tab.queue.rawValue
                showSidePanel = true
            }
        }
        #endif
    }

    /// Opens the right-hand panel on a tab, or closes it when that tab is already showing.
    private func panelButton(_ tab: MacSidePanel.Tab, systemImage: String, help: String) -> some View {
        let active = showSidePanel && panelTab == tab.rawValue
        return Button {
            if active {
                showSidePanel = false
            } else {
                panelTab = tab.rawValue
                showSidePanel = true
            }
        } label: {
            Image(systemName: systemImage)
                .symbolVariant(active ? .fill : .none)
                .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .help(help)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Label(Section.home.title, systemImage: "house").tag(Section.home)

            SwiftUI.Section("Libreria") {
                ForEach(library) { item in
                    Label(item.title, systemImage: item.systemImage).tag(item)
                }
            }

            SwiftUI.Section("Playlist") {
                Label(Section.playlists.title, systemImage: "music.note.list").tag(Section.playlists)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SettingsLink {
                Label("Impostazioni", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        // Typing in the search field shows the results; clearing it goes back.
        .onChange(of: isSearching) { _, searching in
            if !searching, selection == .search { selection = .home }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if isSearching {
            MacSearchView(query: $viewModel.globalSearchQuery)
        } else {
            switch selection ?? .home {
            case .home: MacHomeView()
            case .albums: MacAlbumsView()
            case .artists: MacArtistsView()
            case .tracks: MacTracksView()
            case .genres: MacGenresView()
            case .favorites: MacFavoritesView()
            case .playlists: MacPlaylistsView()
            case .search, .settings: MacHomeView()
            }
        }
    }
}
#endif
