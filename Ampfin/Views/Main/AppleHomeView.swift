// AppleHomeView.swift
// The Home in the style of Apple Music on iOS 26:
// tall "top picks" cards whose bottom takes the cover's color, then strips of square
// covers with the title underneath.

import SwiftUI

/// Which top bar the tabs use (Settings → Barra in alto).
enum TopBarStyle: String, CaseIterable, Identifiable {
    case system, ampfin

    static let storageKey = "topBarStyle"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "Sistema"
        case .ampfin: return "Ampfin"
        }
    }
}

struct AppleHomeView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @Environment(\.scenePhase) private var scenePhase

    /// Worked out when the library or the history changes, not at every redraw
    /// (it shuffles the whole album list).
    @State private var topPicks: [HomePick] = []
    /// Same for the genre strip: counting every album's genre in `body` ran at each of the
    /// many publishes of a refresh, right when the pull-down spring needs the main thread.
    @State private var topGenre: (name: String, albums: [AlbumItem])?
    @ObservedObject private var mixStore = MixStore.shared
    @AppStorage(MixSource.storageKey) private var mixSource = MixSource.ampfin.rawValue
    /// Settings → Mix in Home: mixes as big cards among the top picks, as Apple Music does.
    @AppStorage(MixSource.topPicksKey) private var mixesInTopPicks = true
    /// Settings → Statistiche d'ascolto in Home: the scrobbling section, off by default.
    @AppStorage(ScrobbleStatsStore.homeKey) private var showScrobbleStats = false

    /// The top picks with up to two of Ampfin's mixes among the albums: the day's mix
    /// second, the new music (or discoveries) fourth.
    private var topPickCards: [TopPickCard] {
        var cards = topPicks.map(TopPickCard.album)
        guard mixesInTopPicks, mixSource == MixSource.ampfin.rawValue else { return cards }
        let mixes = mixStore.mixes
        if let daily = mixes.first(where: { $0.kind == .daily }) {
            cards.insert(.mix(daily, caption: "Aggiornato oggi"), at: min(1, cards.count))
        }
        if let made = mixes.first(where: { $0.kind == .fresh }) ?? mixes.first(where: { $0.kind == .discover }) {
            cards.insert(.mix(made, caption: "Fatto per te"), at: min(3, cards.count))
        }
        return cards
    }

    private var recentAlbums: [AlbumItem] {
        viewModel.recentlyPlayedAlbums.isEmpty ? Array(viewModel.albums.prefix(12)) : Array(viewModel.recentlyPlayedAlbums.prefix(12))
    }

    /// The genre with most albums, and its albums.
    private static func makeTopGenre(from albums: [AlbumItem]) -> (name: String, albums: [AlbumItem])? {
        let counts = Dictionary(albums.compactMap(\.Genres?.first).map { ($0, 1) }, uniquingKeysWith: +)
        guard let genre = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return (genre, Array(albums.filter { $0.Genres?.contains(genre) ?? false }.prefix(12)))
    }

    var body: some View {
        #if os(macOS)
        MacHomeView()
        #else
        phoneBody
        #endif
    }

    #if os(iOS)
    private var phoneBody: some View {
        // No scroll bar on the Home: it's a page to browse, not a list to search.
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                HomeGreetingRow()

                if !topPickCards.isEmpty {
                    sectionTitle("Scelti per te")
                        .entrance(.rise)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(topPickCards) { card in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(card.caption)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    switch card {
                                    case .album(let pick):
                                        PickCard(album: pick.album, zoomID: "pick-\(pick.id)")
                                    case .mix(let mix, _):
                                        MixPickCard(mix: mix)
                                    }
                                }
                                .frame(width: 250)
                                .coverFlow()
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .scrollClipDisabled()
                    .entrance(.rise, delay: 0.06)
                }

                mixesSection
                    .entrance(.rise, delay: 0.09)

                sectionLink("Ascoltati di recente", albums: recentAlbums)
                    .entrance(.rise, delay: 0.12)
                AlbumStrip(albums: recentAlbums, group: "recent")
                    .entrance(.rise, delay: 0.16)

                if showScrobbleStats {
                    ScrobbleHomeSection()
                        .id("scrobble-stats")
                        .entrance(.rise, delay: 0.18)
                }

                if !viewModel.recentlyAddedAlbums.isEmpty {
                    sectionLink("Aggiunti di recente", albums: viewModel.recentlyAddedAlbums)
                    AlbumStrip(albums: Array(viewModel.recentlyAddedAlbums.prefix(12)), group: "added")
                }

                playlistsSection

                if !viewModel.favoriteAlbums.isEmpty {
                    sectionLink("I tuoi preferiti", albums: viewModel.favoriteAlbums)
                    AlbumStrip(albums: viewModel.favoriteAlbums, group: "favorites")
                }

                if let genre = topGenre, !genre.albums.isEmpty {
                    sectionTitle(genre.name)
                    AlbumStrip(albums: genre.albums, group: "genre")
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 120)
        }
        #if os(iOS)
        .hidesMiniPlayerOnScroll()
        #endif
        #if DEBUG
        // Only for the screenshot launch flag: a bound ScrollPosition is written while the
        // user scrolls (and rubber-bands), which redrew the whole Home at every frame.
        .modifier(TestScrollPosition(position: $testScroll))
        #endif
        .refreshable {
            await LibraryRefresh.shared.run {
                await viewModel.fetchAllLibraryData()
                if showScrobbleStats {
                    await ScrobbleStatsStore.shared.load(using: viewModel, force: true)
                }
            }
        }
        .libraryRefreshBanner()
        .task(id: "\(viewModel.albums.count)|\(viewModel.currentlyPlayingItem?.Id ?? "")|\(viewModel.recentlyPlayedTracks.first?.Id ?? "")|\(viewModel.recentlyAddedAlbums.first?.Id ?? "")|\(viewModel.favoriteAlbumIds.count)") {
            // Not while a pull-to-refresh is springing back: changing the content then
            // cancels the scroll view's rubber band.
            await LibraryRefresh.shared.settled()
            guard !Task.isCancelled else { return }
            topPicks = viewModel.homePicks()
            topGenre = Self.makeTopGenre(from: viewModel.albums)
        }
        .task {
            await viewModel.fetchRecentlyPlayedAlbumsIfNeeded()
            await viewModel.fetchRecentlyAddedAlbumsIfNeeded()
            await viewModel.fetchRecentlyPlayedTracksIfNeeded()
        }
        // Coming back to the app: new albums may have been added while it was away (TTL applies)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await viewModel.fetchRecentlyAddedAlbumsIfNeeded() }
        }
        // Playlists, and the mixes made again for a new day, user or library.
        .task(id: "\(viewModel.audioItems.count)|\(viewModel.recentlyAddedAlbums.first?.Id ?? "")") {
            await LibraryRefresh.shared.settled()
            await mixStore.refreshPlaylists(viewModel: viewModel)
            await mixStore.refreshMixes(viewModel: viewModel)
        }
        // Listening statistics are fetched only when the section is on.
        .task(id: showScrobbleStats) {
            guard showScrobbleStats else { return }
            await ScrobbleStatsStore.shared.load(using: viewModel)
            #if DEBUG
            // `-provaHomeStatistiche YES` scrolls to the section, to photograph it from the Mac.
            if UserDefaults.standard.bool(forKey: "provaHomeStatistiche") {
                try? await Task.sleep(for: .seconds(1))
                withAnimation { testScroll.scrollTo(id: "scrobble-stats", anchor: .top) }
            }
            #endif
        }
    }

    #if DEBUG
    @State private var testScroll = ScrollPosition(idType: String.self)

    /// Binds the scroll position only when the screenshot flag is on; otherwise the
    /// ScrollView is left alone, as in release builds.
    private struct TestScrollPosition: ViewModifier {
        @Binding var position: ScrollPosition

        @ViewBuilder
        func body(content: Content) -> some View {
            if UserDefaults.standard.bool(forKey: "provaHomeStatistiche") {
                content.scrollPosition($position)
            } else {
                content
            }
        }
    }
    #endif

    /// "Mix per te": Ampfin's own mixes, or the server plugins' playlists (Settings).
    @ViewBuilder
    private var mixesSection: some View {
        if mixSource == MixSource.jellyfin.rawValue {
            if !mixStore.serverMixes.isEmpty {
                sectionTitle("Mix per te")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(mixStore.serverMixes) { playlist in
                            NavigationLink {
                                PlaylistDetailPage(playlist: playlist)
                            } label: {
                                PlaylistTile(playlist: playlist)
                            }
                            .buttonStyle(.pressable)
                            .coverFlow()
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollClipDisabled()
            }
        } else if !mixStore.mixes.isEmpty {
            sectionTitle("Mix per te")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(mixStore.mixes) { mix in
                        NavigationLink {
                            MixDetailPage(mix: mix)
                        } label: {
                            MixCard(mix: mix)
                        }
                        .buttonStyle(.pressable)
                        .contextMenu {
                            Button {
                                viewModel.playerManager.playAlbumShuffled(tracks: mix.tracks)
                            } label: {
                                Label("Riproduci in ordine casuale", systemImage: "shuffle")
                            }
                            QueueMenuItems(tracks: mix.tracks)
                            AddToPlaylistMenu(tracks: mix.tracks)
                        }
                        .coverFlow()
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollClipDisabled()
        }
    }

    /// "Le tue playlist ›", and a strip of them.
    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink {
                PlaylistsPage()
            } label: {
                HStack(spacing: 4) {
                    Text("Le tue playlist")
                        .font(.title2.weight(.bold))
                    Image(systemName: "chevron.right")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 8)
            }
            .buttonStyle(.plain)

            if mixStore.userPlaylists.isEmpty {
                Button {
                    mixStore.pendingNewPlaylist = []
                } label: {
                    Label("Nuova playlist", systemImage: "plus")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .padding(.horizontal, 20)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(mixStore.userPlaylists) { playlist in
                            NavigationLink {
                                PlaylistDetailPage(playlist: playlist)
                            } label: {
                                PlaylistTile(playlist: playlist)
                            }
                            .buttonStyle(.pressable)
                            .coverFlow()
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollClipDisabled()
            }
        }
    }
    #endif

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.title2.weight(.bold))
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    /// Title with a chevron that opens all of them, like "Recently Played ›".
    private func sectionLink(_ title: String, albums: [AlbumItem]) -> some View {
        NavigationLink {
            AlbumGridPage(title: title, albums: albums)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.title2.weight(.bold))
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 8)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
    }
}

#if os(iOS)
/// The personal line under the Home's title, for the "Messaggio per te" style. Tap for the next one.
/// Its own view, observing HomeGreeting, so a change redraws only this row.
private struct HomeGreetingRow: View {
    @ObservedObject private var greeting = HomeGreeting.shared
    @AppStorage(HomeSubtitleStyle.storageKey) private var style = HomeSubtitleStyle.message.rawValue

    var body: some View {
        if style != HomeSubtitleStyle.date.rawValue {
            Text(greeting.line)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.horizontal, 20)
                .padding(.top, 3)
                .contentTransition(.opacity)
                .onTapGesture {
                    withAnimation(.smooth) { greeting.next() }
                }
                .sensoryFeedback(.selection, trigger: greeting.line)
                .accessibilityAddTraits(.isButton)
                .entrance(.rise)
        }
    }
}
#endif

/// Tall card: the cover fills it, and its bottom melts into the cover's own color
/// with the title and artist on it.
private struct PickCard: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let album: AlbumItem
    let zoomID: String

    @State private var palette = HeroPalette.neutral
    @State private var image: PlatformImage?

    var body: some View {
        NavigationLink(destination: AlbumTracksListView(album: album).zoomDestination(zoomID)) {
            ZStack(alignment: .bottom) {
                palette.background

                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 250, height: 250)
                        .clipped()
                        .frame(maxHeight: .infinity, alignment: .top)
                        .transition(.opacity)
                }

                LinearGradient(stops: [.init(color: palette.background.opacity(0), location: 0),
                                       .init(color: palette.background, location: 0.45)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 150)

                VStack(spacing: 2) {
                    Text(album.Name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(album.AlbumArtist ?? "")
                        .font(.subheadline)
                        .opacity(0.8)
                        .lineLimit(1)
                    if let year = album.ProductionYear {
                        Text(String(year))
                            .font(.caption)
                            .opacity(0.7)
                    }
                }
                .foregroundStyle(palette.foreground)
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            }
            .frame(width: 250, height: 330)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .zoomSource(zoomID)
        }
        .buttonStyle(.pressable)
        .animation(.easeInOut(duration: 0.4), value: palette)
        .task(id: album.Id) {
            guard let url = viewModel.artworkURL(for: album.id, size: 600),
                  let loaded = await ImageLoader.shared.firstImage(from: [url]) else { return }
            image = loaded
            if let colors = HeroPalette(image: loaded) { palette = colors }
        }
    }
}

/// A strip of square covers with title and artist underneath.
/// A strip of square covers with title and artist underneath (also used by Favorites).
struct AlbumStrip: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let albums: [AlbumItem]
    let group: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(albums) { album in
                    AlbumTile(album: album, zoomID: "\(group)-\(album.id)")
                        .coverFlow()
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollClipDisabled()
    }
}

struct AlbumTile: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let album: AlbumItem
    let zoomID: String
    var size: CGFloat = 160

    var body: some View {
        NavigationLink(destination: AlbumTracksListView(album: album).zoomDestination(zoomID)) {
            VStack(alignment: .leading, spacing: 4) {
                CachedAsyncImage(url: viewModel.artworkURL(for: album.id, size: 400), targetSize: size,
                    content: { $0.resizable().aspectRatio(contentMode: .fill) },
                    placeholder: { RoundedRectangle(cornerRadius: 8).fill(.quaternary) }
                )
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .zoomSource(zoomID)

                Text(album.Name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(album.AlbumArtist ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: size, alignment: .leading)
        }
        .buttonStyle(.pressable)
        .contextMenu {
            AlbumQueueMenuItems(album: album)
            Divider()
            Button {
                viewModel.toggleFavoriteAlbum(album.id)
            } label: {
                Label(viewModel.isAlbumFavorite(album.id) ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti",
                      systemImage: viewModel.isAlbumFavorite(album.id) ? "heart.slash" : "heart")
            }
        }
    }
}

/// "See all" for a section: every album in a grid.
struct AlbumGridPage: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let title: String
    let albums: [AlbumItem]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 18) {
                ForEach(albums) { album in
                    AlbumTile(album: album, zoomID: "all-\(album.id)", size: 170)
                        .gridSettle()
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 120)
        }
        .navigationTitle(title)
    }
}

private extension Array {
    /// A shuffle that stays the same all day, so the picks don't jump at every refresh.
    func shuffledStable(seed: Int) -> [Element] {
        var generator = SeededGenerator(seed: UInt64(seed))
        return shuffled(using: &generator)
    }

    func randomElementStable(seed: Int) -> Element? {
        shuffledStable(seed: seed).first
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

// MARK: - Top picks

struct HomePick: Identifiable {
    let id: String
    let caption: String
    let album: AlbumItem
}

/// A card of "Scelti per te": an album, or one of Ampfin's mixes.
enum TopPickCard: Identifiable {
    case album(HomePick)
    case mix(Mix, caption: String)

    var id: String {
        switch self {
        case .album(let pick): return pick.id
        case .mix(let mix, _): return "mix-\(mix.id)"
        }
    }

    var caption: String {
        switch self {
        case .album(let pick): return pick.caption
        case .mix(_, let caption): return caption
        }
    }
}

/// A mix as a top pick, the size of the album cards: its four covers on top, the bottom
/// in the first cover's color, title and the artists inside.
private struct MixPickCard: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let mix: Mix

    @State private var palette = HeroPalette.neutral

    var body: some View {
        NavigationLink {
            MixDetailPage(mix: mix)
        } label: {
            ZStack(alignment: .bottom) {
                palette.background

                CoverGrid(albumIds: mix.coverAlbumIds, size: 250)
                    .frame(maxHeight: .infinity, alignment: .top)

                LinearGradient(stops: [.init(color: palette.background.opacity(0), location: 0),
                                       .init(color: palette.background, location: 0.45)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 150)

                VStack(spacing: 2) {
                    Label(mix.title, systemImage: mix.kind.systemImage)
                        .font(.headline)
                        .lineLimit(1)
                    Text(mix.subtitle)
                        .font(.subheadline)
                        .opacity(0.8)
                        .lineLimit(1)
                    Text("\(mix.tracks.count) brani")
                        .font(.caption)
                        .opacity(0.7)
                }
                .foregroundStyle(palette.foreground)
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            }
            .frame(width: 250, height: 330)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.pressable)
        .contextMenu {
            Button {
                viewModel.playerManager.playAlbumShuffled(tracks: mix.tracks)
            } label: {
                Label("Riproduci in ordine casuale", systemImage: "shuffle")
            }
            QueueMenuItems(tracks: mix.tracks)
            AddToPlaylistMenu(tracks: mix.tracks)
        }
        .animation(.easeInOut(duration: 0.4), value: palette)
        // The colors of the cover at the bottom left, the one the band continues from.
        .task(id: mix.coverAlbumIds.last ?? "") {
            guard let id = mix.coverAlbumIds.count >= 4 ? mix.coverAlbumIds[2] : mix.coverAlbumIds.first,
                  let url = viewModel.artworkURL(for: id, size: 300),
                  let loaded = await ImageLoader.shared.firstImage(from: [url]),
                  let colors = HeroPalette(image: loaded) else { return }
            palette = colors
        }
    }
}

extension JellyfinViewModel {
    private static var dayOfYear: Int {
        Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
    }

    /// The song playing, or else the last one played, and its album: the first top pick.
    private var lastListened: (song: AudioItem, album: AlbumItem)? {
        for song in [currentlyPlayingItem].compactMap({ $0 }) + recentlyPlayedTracks {
            if let albumId = song.AlbumId, let album = albums.first(where: { $0.Id == albumId }) {
                return (song, album)
            }
        }
        return nil
    }

    /// First the album of the last song heard, then one each from what you love and what
    /// just arrived, then a few you haven't heard in a while.
    func homePicks() -> [HomePick] {
        var picks: [HomePick] = []
        var used = Set<String>()
        // The id leaves out the song, so the card isn't rebuilt when the next one starts.
        func add(_ album: AlbumItem?, _ caption: String, key: String? = nil) {
            guard let album, used.insert(album.Id).inserted else { return }
            picks.append(HomePick(id: "\(key ?? caption)-\(album.Id)", caption: caption, album: album))
        }
        let last = lastListened
        if let last {
            let playing = currentlyPlayingItem?.Id == last.song.Id
            add(last.album, "\(playing ? "In ascolto" : "Ultimo ascolto") · \(last.song.Name)", key: "last")
        }
        add(favoriteAlbums.randomElementStable(seed: Self.dayOfYear), "Tra i tuoi preferiti")
        add(recentlyAddedAlbums.first, "Appena aggiunto")
        if let artist = last?.album.AlbumArtist {
            add(albums.first { $0.AlbumArtist == artist && !used.contains($0.Id) }, "Altro di \(artist)")
        }
        let played = Set(recentlyPlayedAlbums.map(\.Id))
        for album in albums.filter({ !played.contains($0.Id) }).shuffledStable(seed: Self.dayOfYear).prefix(3) {
            add(album, "Da riscoprire")
        }
        return picks
    }
}
