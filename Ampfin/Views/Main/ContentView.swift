import SwiftUI

// Environment key for mini player visibility binding
private struct MiniPlayerVisibleKey: EnvironmentKey {
    static let defaultValue: Binding<Bool> = .constant(true)
}

extension EnvironmentValues {
    var miniPlayerVisible: Binding<Bool> {
        get { self[MiniPlayerVisibleKey.self] }
        set { self[MiniPlayerVisibleKey.self] = newValue }
    }
}

struct ContentView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var colorManager = AccentColorManager.shared

    // Sidebar / Tab selection
    enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
        case home, tracks, albums, artists, genres, playlists, favorites, settings, search

        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: return "Home"
            case .tracks: return "Brani"
            case .albums: return "Album"
            case .artists: return "Artisti"
            case .genres: return "Generi"
            case .playlists: return "Playlist"
            case .favorites: return "Preferiti"
            case .settings: return "Impostazioni"
            case .search: return "Cerca"
            }
        }

        var systemImage: String {
            switch self {
            case .home: return "house"
            case .tracks: return "music.note.list"
            case .albums: return "square.stack.fill"
            case .artists: return "music.mic"
            case .genres: return "guitars.fill"
            case .playlists: return "music.note.list"
            case .favorites: return "heart.fill"
            case .settings: return "gearshape"
            case .search: return "magnifyingglass"
            }
        }
    }

    @State private var selectedSidebar: SidebarItem? = .home
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showFullPlayer: Bool = false
    @State private var miniPlayerVisible: Bool = true
    /// The cover morphs between the mini player and the full player.
    @Namespace private var playerArtwork

    var body: some View {
        mainBody
            // The name prompt of "Nuova playlist…", from any song menu.
            .modifier(NewPlaylistPrompt())
            // "Riprodotto dopo" / "Aggiunto alla coda" drops in at the top.
            .overlay(alignment: .top) { QueueToast() }
            // Links from the widgets: ampfin://player and ampfin://album/<id>.
            .onOpenURL(perform: openLink)
            .sheet(item: $linkedAlbum) { album in
                NavigationStack {
                    AlbumTracksListView(album: album)
                }
                .environmentObject(viewModel)
            }
            // The accent can follow the cover of the album that's playing.
            .task(id: viewModel.currentlyPlayingItem.map { $0.AlbumId ?? $0.id }) {
                await updateArtworkAccent()
            }
            // The optional album-colored background (Settings > Aspetto).
            .task(id: viewModel.currentlyPlayingItem.map { $0.AlbumId ?? $0.id }) {
                guard let item = viewModel.currentlyPlayingItem else { return }
                let albumId = item.AlbumId ?? item.id
                await AlbumBackdrop.shared.show(albumId: albumId, url: viewModel.artworkURL(for: albumId, size: 300))
            }
    }

    @State private var linkedAlbum: AlbumItem?

    private func openLink(_ url: URL) {
        guard url.scheme == "ampfin" else { return }
        switch url.host() {
        case "player":
            guard viewModel.currentlyPlayingItem != nil else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) { showFullPlayer = true }
        case "album":
            let id = url.lastPathComponent
            linkedAlbum = viewModel.albums.first { $0.Id == id }
        default:
            break
        }
    }

    private func updateArtworkAccent() async {
        guard let item = viewModel.currentlyPlayingItem,
              let url = viewModel.artworkURL(for: item.AlbumId ?? item.id, size: 300),
              let image = await ImageLoader.shared.firstImage(from: [url]),
              let color = image.averageColor() else { return }
        // No animation: an animated tint redraws the whole app on every frame, and it
        // ran exactly while the album page morphed its buttons, making them stutter.
        colorManager.artworkAccent = color.legibleAccent()
    }

    @ViewBuilder
    private var mainBody: some View {
        if !viewModel.isLoggedIn {
            LoginView()
                #if os(macOS)
                .frame(minWidth: 800, minHeight: 600)
                #endif
                .onAppear {
                    print("[ContentView] Showing LoginView (user NOT logged in)")
                }
        } else {
            #if os(macOS)
            macOSContent
            #else
            iOSContent
            #endif
        }
    }

    // MARK: - macOS Layout

    #if os(macOS)
    private var macOSContent: some View {
        MacShell()
            .task { await loadLibraryIfNeeded() }
    }
    #endif

    // MARK: - iOS Layout

    #if os(iOS)
    @State private var selectedTab: SidebarItem = .home
    /// The Album and Artisti stacks, so "Vai all'album/artista" can open a page in them.
    @State private var albumsPath = NavigationPath()
    @State private var artistsPath = NavigationPath()
    @ObservedObject private var navigator = LibraryNavigator.shared
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage(CoverFlowSettings.storageKey) private var landscapeCoverFlow = false

    /// Full-screen Cover Flow only when the phone is sideways (compact height).
    private var showLandscapeCoverFlow: Bool {
        landscapeCoverFlow && verticalSizeClass == .compact
    }

    /// "Vai all'artista" / "Vai all'album": closes the player and the album sheet, moves
    /// to that tab and opens the page on a fresh stack.
    private func handle(_ request: LibraryNavigator.Request?) {
        guard let request else { return }
        showFullPlayer = false
        linkedAlbum = nil
        switch request.destination {
        case .artist(let artist):
            selectedTab = .artists
            artistsPath = NavigationPath([artist])
        case .album(let album):
            selectedTab = .albums
            albumsPath = NavigationPath([album])
        }
    }

    private var iOSContent: some View {
        ZStack {
            // Main tab content
            TabView(selection: $selectedTab) {
                Tab(SidebarItem.home.title, systemImage: SidebarItem.home.systemImage, value: .home) {
                    // Zoom transitions from covers to their pages.
                    ZoomScope {
                        NavigationStack {
                            AppleHomeView()
                                .albumColorBackground()
                                .homeToolbar(viewModel: viewModel)
                        }
                    }
                }

                Tab(SidebarItem.tracks.title, systemImage: SidebarItem.tracks.systemImage, value: .tracks) {
                    // Zoom transitions from covers to their pages.
                    ZoomScope {
                        NavigationStack {
                            TracksView()
                                .albumColorBackground()
                                .iOSToolbar(viewModel: viewModel, title: "Brani",
                                            subtitle: countLabel(viewModel.audioItems.count, one: "brano", many: "brani"))
                        }
                    }
                }

                Tab(SidebarItem.albums.title, systemImage: SidebarItem.albums.systemImage, value: .albums) {
                    // Zoom transitions from covers to their pages.
                    ZoomScope {
                        NavigationStack(path: $albumsPath) {
                            AlbumsView()
                                .albumColorBackground()
                                .iOSToolbar(viewModel: viewModel, title: "Album",
                                            subtitle: countLabel(viewModel.albums.count, one: "album", many: "album"))
                        }
                    }
                }

                Tab(SidebarItem.artists.title, systemImage: SidebarItem.artists.systemImage, value: .artists) {
                    // Zoom transitions from covers to their pages.
                    ZoomScope {
                        NavigationStack(path: $artistsPath) {
                            ArtistsView()
                                .albumColorBackground()
                                .iOSToolbar(viewModel: viewModel, title: "Artisti",
                                            subtitle: countLabel(viewModel.artists.count, one: "artista", many: "artisti"))
                        }
                    }
                }

                // Titled in Italian like the other tabs (untitled, iOS writes "Search").
                Tab("Cerca", systemImage: "magnifyingglass", value: .search, role: .search) {
                    // Zoom transitions from covers to their pages.
                    ZoomScope {
                        NavigationStack {
                            SearchResultsView(query: $viewModel.globalSearchQuery)
                                .albumColorBackground()
                                .environmentObject(viewModel)
                                .searchable(text: $viewModel.globalSearchQuery, placement: .toolbar, prompt: "Cerca brani, album, artisti...")
                        }
                    }
                }
            }
            // The mini player is iOS 26's own accessory above the tabs,
            // which shrinks next to them while scrolling down, as in Apple Music.
            .tabBarMinimizeBehavior(.onScrollDown)
            .nowPlayingAccessory(isEnabled: viewModel.currentlyPlayingItem != nil) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) {
                    showFullPlayer = true
                }
            }
            .environment(\.miniPlayerVisible, $miniPlayerVisible)

            // Player layer
            if let playingItem = viewModel.currentlyPlayingItem {
                ZStack {
                    if showFullPlayer {
                        // Full player — its own Liquid Glass elements materialize in place
                        // (no shape-morph from the mini bar; see NowPlayingFullView doc comment).
                        ClockReader(clock: viewModel.clock) { time in NowPlayingFullView(
                            item: playingItem,
                            isPlaying: viewModel.isPlaying,
                            currentTime: time,
                            duration: playingItem.duration ?? 0,
                            artworkURL: viewModel.artworkURL(for: playingItem.AlbumId ?? playingItem.id, size: 600),
                            onPlayPause: { viewModel.playerManager.togglePlayPause() },
                            onBackward: { viewModel.playerManager.backward() },
                            onForward: { viewModel.playerManager.forward() },
                            onSeek: { time in viewModel.playerManager.seek(to: time) },
                            isExpanded: $showFullPlayer,
                            artworkNamespace: playerArtwork
                        ) }
                        // Slides as one sheet; materializing its glass pieces on top
                        // of the slide flickered at the end.
                        .glassEffectTransition(.identity)
                        // Rises from the accessory like a sheet.
                        .transition(.move(edge: .bottom))
                        // Stays above the tabs while it slides out, instead of dropping behind
                        // them for the last frames of the removal.
                        .zIndex(1)
                    }
                }
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.88), value: showFullPlayer)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: miniPlayerVisible)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.currentlyPlayingItem != nil)
        .task {
            await loadLibraryIfNeeded()
            // For "Aggiungi a playlist" in the song menus.
            await MixStore.shared.refreshPlaylists(viewModel: viewModel)
        }
        .onChange(of: navigator.request) { _, request in handle(request) }
        // Above the tabs, the mini player and the full player; the contentShape keeps
        // touches from reaching what is underneath.
        .overlay {
            ZStack {
                if showLandscapeCoverFlow {
                    LandscapeCoverFlow()
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
            }
            // Only the fade of the Cover Flow: on the whole content it animated the
            // rotation of every screen underneath too.
            .animation(.easeInOut(duration: 0.3), value: showLandscapeCoverFlow)
        }
        .statusBarHidden(showLandscapeCoverFlow)
        #if DEBUG
        .task { await applyTestLaunchArguments() }
        .sheet(isPresented: $testFavorites) {
            NavigationStack { FavoritesView() }
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $testStats) {
            NavigationStack { ScrobbleStatsPage() }
                .environmentObject(viewModel)
        }
        #endif
    }

    #if DEBUG
    @State private var testFavorites = false
    @State private var testStats = false

    /// Test-only launch arguments, to photograph screens on the phone from the Mac:
    /// `-provaScheda artists` opens a tab; `-provaPlay <artist>` starts that artist,
    /// pauses straight away and opens the full player (`-provaMini YES`: mini player only).
    private func applyTestLaunchArguments() async {
        let defaults = UserDefaults.standard
        if let tab = defaults.string(forKey: "provaScheda").flatMap(SidebarItem.init(rawValue:)) {
            selectedTab = tab
        }
        // `-provaPreferiti YES` opens the favorites page.
        testFavorites = defaults.bool(forKey: "provaPreferiti")
        // `-provaStatistiche YES` opens the listening statistics.
        testStats = defaults.bool(forKey: "provaStatistiche")
        // `-provaScarica YES` starts "Scarica tutti" on the favorites, as the button does.
        if defaults.bool(forKey: "provaScarica") {
            for _ in 0..<60 where viewModel.audioItems.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
            }
            viewModel.favoriteTracks.filter { !viewModel.isTrackDownloaded($0.Id) }.forEach(viewModel.downloadTrack)
        }
        guard let name = defaults.string(forKey: "provaPlay") else { return }
        for _ in 0..<60 where viewModel.audioItems.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let artist = viewModel.artists.first(where: { $0.Name.localizedCaseInsensitiveCompare(name) == .orderedSame }),
              let first = viewModel.tracks(byArtist: artist).first else { return }
        viewModel.playerManager.play(item: first, in: viewModel.tracks(byArtist: artist))
        // Pause only once the sound has really started (isPlaying turns true before
        // the download ends), or the audio would start after the pause.
        for _ in 0..<60 where viewModel.currentTime <= 0 {
            try? await Task.sleep(for: .milliseconds(250))
        }
        viewModel.playerManager.pause()
        // `-provaMini YES` leaves the mini player instead of opening the full one.
        showFullPlayer = !defaults.bool(forKey: "provaMini")
    }
    #endif
    #endif

    // MARK: - Shared

    @ViewBuilder
    private func detailView(for item: SidebarItem?) -> some View {
        switch item {
        case .home, .none:
            AppleHomeView()
        case .tracks:
            TracksView()
        case .albums:
            AlbumsView()
        case .artists:
            ArtistsView()
        case .genres:
            GenresView()
        case .playlists:
            GeneratedPlaylistsView()
        case .favorites:
            FavoritesView()
        case .settings:
            SettingsView()
        case .search:
            SearchResultsView(query: $viewModel.globalSearchQuery)
        }
    }

    /// "8.012 brani"; nil while the library is still loading.
    private func countLabel(_ count: Int, one: String, many: String) -> String? {
        guard count > 0 else { return nil }
        return "\(count.formatted()) \(count == 1 ? one : many)"
    }

    private func loadLibraryIfNeeded() async {
        // If in-memory data is empty, try loading from disk cache first
        if viewModel.audioItems.isEmpty {
            let cacheLoaded = await viewModel.loadLibraryFromCacheIfAvailable()
            if !cacheLoaded {
                // No cache — must fetch from API
                await viewModel.fetchAllLibraryData()
                return
            }
        }
        // If cache is stale, refresh from API in background (UI already populated)
        if viewModel.isLibraryCacheStale() {
            await viewModel.fetchAllLibraryData()
        }
    }

    #if os(macOS)
    private func toggleSidebarVisibility() {
        switch columnVisibility {
        case .all:
            columnVisibility = .detailOnly
        case .detailOnly:
            columnVisibility = .all
        case .automatic:
            columnVisibility = .all
        default:
            columnVisibility = .all
        }
    }
    #endif
}

// MARK: - iOS Toolbar Modifier

#if os(iOS)
private struct IOSToolbarModifier: ViewModifier {
    @ObservedObject var viewModel: JellyfinViewModel
    var title: String? = nil
    var subtitle: String? = nil
    var onSubtitleTap: (() -> Void)? = nil
    @ObservedObject private var colorManager = AccentColorManager.shared

    // Same size as iOS 26's own toolbar groups: 44 pt tall, a 48 pt slot per icon.
    private func toolbarIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 48, height: 44)
            .contentShape(Rectangle())
    }

    @AppStorage(TopBarStyle.storageKey) private var topBarStyle = TopBarStyle.system.rawValue

    @ViewBuilder
    func body(content: Content) -> some View {
        if topBarStyle == TopBarStyle.ampfin.rawValue {
            // Our own bar instead of the system one, so the buttons can be as big as we like.
            // Only on the tab's root: the pages it opens keep the system bar and Back.
            content
                .navigationTitle(title ?? "amplifin")
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaBar(edge: .top) {
                    AmpfinTopBar(viewModel: viewModel, title: title ?? "amplifin", subtitle: subtitle, onSubtitleTap: onSubtitleTap)
                }
        } else {
            systemBar(content)
        }
    }

    /// The system navigation bar: inline large title, subtitle, accent capsule.
    private func systemBar(_ content: Content) -> some View {
        content
            .navigationTitle(title ?? "amplifin")
            // Large bold title on the same row as the buttons, as in Photos on iOS 26.
            .toolbarTitleDisplayMode(.inlineLarge)
            // A second line under the title makes the bar taller, so the buttons aren't squeezed.
            .modifier(OptionalSubtitle(text: subtitle))
            // One capsule of glass tinted with the accent (the playing album's color when
            // that option is on), at the size of iOS 26's toolbar groups. Logout lives in Settings.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 2) {
                        NavigationLink(destination: FavoritesView().environmentObject(viewModel)) {
                            toolbarIcon("heart.fill")
                        }
                        .accessibilityLabel("Preferiti")

                        NavigationLink(destination: SettingsView().environmentObject(viewModel)) {
                            toolbarIcon("gearshape.fill")
                        }
                        .accessibilityLabel("Impostazioni")
                    }
                    .padding(.horizontal, 6)
                    .glassEffect(.regular.tint(Color.accentColor.opacity(0.85)).interactive(), in: .capsule)
                }
                .sharedBackgroundVisibility(.hidden)
            }
    }
}

/// The custom top bar: large title and subtitle on the left, a big accent-tinted glass
/// capsule on the right. It sits in a `safeAreaBar`, so content scrolls under it with
/// the system's edge blur.
private struct AmpfinTopBar: View {
    @ObservedObject var viewModel: JellyfinViewModel
    let title: String
    let subtitle: String?
    /// A tap on the subtitle (the Home cycles its messages); the system bar can't take one.
    var onSubtitleTap: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.25), value: subtitle)
                        .onTapGesture { onSubtitleTap?() }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                NavigationLink(destination: FavoritesView().environmentObject(viewModel)) {
                    icon("heart.fill")
                }
                .accessibilityLabel("Preferiti")
                NavigationLink(destination: SettingsView().environmentObject(viewModel)) {
                    icon("gearshape.fill")
                }
                .accessibilityLabel("Impostazioni")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .glassEffect(.regular.tint(Color.accentColor.opacity(0.85)).interactive(), in: .capsule)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private func icon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 54, height: 52)
            .contentShape(Rectangle())
    }
}

private struct OptionalSubtitle: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.navigationSubtitle(text)
        } else {
            content
        }
    }
}

extension View {
    func iOSToolbar(viewModel: JellyfinViewModel, title: String? = nil, subtitle: String? = nil,
                    onSubtitleTap: (() -> Void)? = nil) -> some View {
        modifier(IOSToolbarModifier(viewModel: viewModel, title: title, subtitle: subtitle, onSubtitleTap: onSubtitleTap))
    }
}

/// Modifier that hides the mini player when the user scrolls down and shows it when scrolling up.
struct ScrollHidesMiniPlayer: ViewModifier {
    @Environment(\.miniPlayerVisible) var miniPlayerVisible
    @State private var lastOffset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { oldOffset, newOffset in
                let delta = newOffset - lastOffset
                // Only react to meaningful scroll movements
                if abs(delta) > 4 {
                    let scrollingDown = delta > 0 && newOffset > 0
                    // Write only on a real change: every write redraws the root view and its tabs.
                    if miniPlayerVisible.wrappedValue == scrollingDown {
                        miniPlayerVisible.wrappedValue = !scrollingDown
                    }
                    lastOffset = newOffset
                }
            }
    }
}

extension View {
    func hidesMiniPlayerOnScroll() -> some View {
        modifier(ScrollHidesMiniPlayer())
    }
}
#endif
