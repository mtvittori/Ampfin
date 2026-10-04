// AppleHomeView.swift
// The Home in the style of Apple Music on iOS 26 (Settings → Home → Apple Music):
// tall "top picks" cards whose bottom takes the cover's color, then strips of square
// covers with the title underneath.

import SwiftUI

/// Which Home the classic look shows.
enum HomeStyle: String, CaseIterable, Identifiable {
    case classic, appleMusic

    static let storageKey = "homeStyle"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .classic: return "Classica"
        case .appleMusic: return "Apple Music"
        }
    }
}

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

    private struct Pick: Identifiable {
        let id: String
        let caption: String
        let album: AlbumItem
    }

    /// Worked out when the library or the history changes, not at every redraw
    /// (it shuffles the whole album list).
    @State private var topPicks: [Pick] = []

    /// One card each from what you played, what you love and what just arrived,
    /// then a few you haven't heard in a while.
    private func computePicks() -> [Pick] {
        var picks: [Pick] = []
        var used = Set<String>()
        func add(_ album: AlbumItem?, _ caption: String) {
            guard let album, used.insert(album.Id).inserted else { return }
            picks.append(Pick(id: "\(caption)-\(album.Id)", caption: caption, album: album))
        }
        add(viewModel.recentlyPlayedAlbums.first, "Da riprendere")
        add(viewModel.favoriteAlbums.randomElementStable(seed: dayOfYear), "Tra i tuoi preferiti")
        add(viewModel.recentlyAddedAlbums.first, "Appena aggiunto")
        if let artist = viewModel.recentlyPlayedAlbums.first?.AlbumArtist {
            add(viewModel.albums.first { $0.AlbumArtist == artist && !used.contains($0.Id) }, "Altro di \(artist)")
        }
        let played = Set(viewModel.recentlyPlayedAlbums.map(\.Id))
        for album in viewModel.albums.filter({ !played.contains($0.Id) }).shuffledStable(seed: dayOfYear).prefix(3) {
            add(album, "Da riscoprire")
        }
        return picks
    }

    private var dayOfYear: Int {
        Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
    }

    private var recentAlbums: [AlbumItem] {
        viewModel.recentlyPlayedAlbums.isEmpty ? Array(viewModel.albums.prefix(12)) : Array(viewModel.recentlyPlayedAlbums.prefix(12))
    }

    /// The genre with most albums, and its albums.
    private var topGenre: (name: String, albums: [AlbumItem])? {
        let counts = Dictionary(viewModel.albums.compactMap(\.Genres?.first).map { ($0, 1) }, uniquingKeysWith: +)
        guard let genre = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return (genre, Array(viewModel.albums.filter { $0.Genres?.contains(genre) ?? false }.prefix(12)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !topPicks.isEmpty {
                    sectionTitle("Scelti per te")
                        .entrance(.rise)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(topPicks) { pick in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(pick.caption)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    PickCard(album: pick.album, zoomID: "pick-\(pick.id)")
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

                sectionLink("Ascoltati di recente", albums: recentAlbums)
                    .entrance(.rise, delay: 0.12)
                AlbumStrip(albums: recentAlbums, group: "recent")
                    .entrance(.rise, delay: 0.16)

                if !viewModel.recentlyAddedAlbums.isEmpty {
                    sectionLink("Aggiunti di recente", albums: viewModel.recentlyAddedAlbums)
                    AlbumStrip(albums: Array(viewModel.recentlyAddedAlbums.prefix(12)), group: "added")
                }

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
        .refreshable {
            await viewModel.fetchAllLibraryData()
        }
        .task(id: "\(viewModel.albums.count)|\(viewModel.recentlyPlayedAlbums.first?.Id ?? "")|\(viewModel.recentlyAddedAlbums.first?.Id ?? "")|\(viewModel.favoriteAlbumIds.count)") {
            topPicks = computePicks()
        }
        .task {
            await viewModel.fetchRecentlyPlayedAlbumsIfNeeded()
            await viewModel.fetchRecentlyAddedAlbumsIfNeeded()
            await viewModel.fetchRecentlyPlayedTracksIfNeeded()
        }
    }

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
                  let loaded = await ZuneImageLoader.shared.firstImage(from: [url]) else { return }
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
