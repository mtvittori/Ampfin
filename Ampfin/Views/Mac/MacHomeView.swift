// MacHomeView.swift
// The Home on the Mac: big picks for you, then strips of covers for what you played,
// what just arrived and what you love, each title opening the full grid.

#if os(macOS)
import SwiftUI

struct MacHomeView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @State private var topPicks: [HomePick] = []

    private var recentAlbums: [AlbumItem] {
        viewModel.recentlyPlayedAlbums.isEmpty ? Array(viewModel.albums.prefix(20)) : Array(viewModel.recentlyPlayedAlbums.prefix(20))
    }

    /// The genre with most albums, and its albums.
    private var topGenre: (name: String, albums: [AlbumItem])? {
        let counts = Dictionary(viewModel.albums.compactMap(\.Genres?.first).map { ($0, 1) }, uniquingKeysWith: +)
        guard let genre = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return (genre, Array(viewModel.albums.filter { $0.Genres?.contains(genre) ?? false }.prefix(20)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                MacPageHeader(title: "Home", subtitle: Date().formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "it_IT"))).capitalized)
                if !topPicks.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        MacSectionTitle(title: "Scelti per te")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 20) {
                                ForEach(topPicks) { pick in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(pick.caption).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                        MacPickCard(album: pick.album)
                                    }
                                    .frame(width: 270)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .scrollClipDisabled()
                    }
                }

                strip("Ascoltati di recente", albums: recentAlbums)
                if !viewModel.recentlyAddedAlbums.isEmpty {
                    strip("Aggiunti di recente", albums: viewModel.recentlyAddedAlbums)
                }
                if !viewModel.favoriteAlbums.isEmpty {
                    strip("I tuoi preferiti", albums: viewModel.favoriteAlbums)
                }
                if let genre = topGenre, !genre.albums.isEmpty {
                    strip(genre.name, albums: genre.albums, linked: false)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
        .macScrollTracking()
        .navigationTitle("Home")
        .task(id: "\(viewModel.albums.count)|\(viewModel.recentlyPlayedAlbums.first?.Id ?? "")|\(viewModel.recentlyAddedAlbums.first?.Id ?? "")|\(viewModel.favoriteAlbumIds.count)") {
            topPicks = viewModel.homePicks()
        }
        .task {
            await viewModel.fetchRecentlyPlayedAlbumsIfNeeded()
            await viewModel.fetchRecentlyAddedAlbumsIfNeeded()
            await viewModel.fetchRecentlyPlayedTracksIfNeeded()
        }
    }

    private func strip(_ title: String, albums: [AlbumItem], linked: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if linked {
                NavigationLink {
                    MacAlbumGridPage(title: title, albums: fullList(for: title, fallback: albums))
                } label: {
                    HStack(spacing: 4) {
                        MacSectionTitle(title: title)
                        Image(systemName: "chevron.right").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            } else {
                MacSectionTitle(title: title)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 24) {
                    ForEach(albums) { album in
                        MacAlbumCard(album: album).frame(width: 180)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
        }
    }

    /// The strips show twenty; their "see all" page shows everything of that kind.
    private func fullList(for title: String, fallback: [AlbumItem]) -> [AlbumItem] {
        switch title {
        case "Ascoltati di recente": return viewModel.recentlyPlayedAlbums.isEmpty ? fallback : viewModel.recentlyPlayedAlbums
        case "Aggiunti di recente": return viewModel.recentlyAddedAlbums
        case "I tuoi preferiti": return viewModel.favoriteAlbums
        default: return fallback
        }
    }
}

/// "See all" for a strip: every album in the grid.
struct MacAlbumGridPage: View {
    let title: String
    let albums: [AlbumItem]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: macAlbumColumns, alignment: .leading, spacing: 26) {
                ForEach(albums) { MacAlbumCard(album: $0) }
            }
            .padding(28)
        }
        .macScrollTracking()
        .navigationTitle(title)
        .navigationSubtitle("\(albums.count.formatted()) album")
    }
}

/// Tall card: the cover fills it and its bottom melts into the cover's own color,
/// with the title and artist on it.
private struct MacPickCard: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let album: AlbumItem

    @State private var palette = HeroPalette.neutral
    @State private var image: PlatformImage?
    @State private var hovering = false

    var body: some View {
        NavigationLink(value: album) {
            ZStack(alignment: .bottom) {
                palette.background

                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 270, height: 270)
                        .clipped()
                        .frame(maxHeight: .infinity, alignment: .top)
                        .transition(.opacity)
                }

                LinearGradient(stops: [.init(color: palette.background.opacity(0), location: 0),
                                       .init(color: palette.background, location: 0.45)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 150)

                VStack(spacing: 2) {
                    Text(album.Name).font(.headline).lineLimit(1)
                    Text(album.AlbumArtist ?? "").font(.subheadline).opacity(0.8).lineLimit(1)
                    if let year = album.ProductionYear {
                        Text(String(year)).font(.caption).opacity(0.7)
                    }
                }
                .foregroundStyle(palette.foreground)
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            }
            .frame(width: 270, height: 350)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(hovering ? 0.28 : 0.16), radius: hovering ? 14 : 8, y: 4)
            .scaleEffect(hovering ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeInOut(duration: 0.4), value: palette)
        .contextMenu { AlbumQueueMenuItems(album: album).environmentObject(viewModel) }
        .task(id: album.Id) {
            guard let url = viewModel.artworkURL(for: album.id, size: 600),
                  let loaded = await ImageLoader.shared.firstImage(from: [url]) else { return }
            image = loaded
            if let colors = HeroPalette(image: loaded) { palette = colors }
        }
    }
}
#endif
