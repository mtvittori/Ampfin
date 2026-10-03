// ZuneScreens.swift
// Zune versions of Home, Songs, Albums and Favorites, used when "Stile Zune" is on.

import SwiftUI

// MARK: - Home

/// Zune HD quickplay: the playing artist behind everything, what's on now at the top,
/// then favorites and history as strips of square covers.
struct ZuneHomeView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    private var heroItem: AudioItem? {
        viewModel.currentlyPlayingItem ?? viewModel.recentlyPlayedTracks.first ?? viewModel.audioItems.first
    }

    private var recentAlbums: [AlbumItem] {
        if !viewModel.recentlyPlayedAlbums.isEmpty { return Array(viewModel.recentlyPlayedAlbums.prefix(12)) }
        if !viewModel.recentlyAddedAlbums.isEmpty { return Array(viewModel.recentlyAddedAlbums.prefix(12)) }
        return Array(viewModel.albums.prefix(12))
    }

    var body: some View {
        ZuneScreen(title: "amplifin", backdropURLs: heroItem.map { viewModel.artistImageURLs(for: $0) } ?? [], dim: 0.5) {
            VStack(alignment: .leading, spacing: 0) {
                if let item = heroItem {
                    ZuneSectionTitle(text: viewModel.currentlyPlayingItem == nil ? "riprendi" : "in ascolto")
                    hero(item)
                }
            }
            .padding(.horizontal, 20)

            if !viewModel.favoriteAlbums.isEmpty || !viewModel.favoriteTracks.isEmpty {
                ZuneSectionTitle(text: "preferiti")
                    .padding(.horizontal, 20)
                ZuneStrip {
                    ForEach(viewModel.favoriteAlbums) { album in
                        ZuneAlbumTile(album: album, size: 140)
                    }
                    ForEach(viewModel.favoriteTracks) { track in
                        ZuneTrackTile(track: track, queue: viewModel.favoriteTracks, size: 140)
                    }
                }
            }

            ZuneSectionTitle(text: "ascoltati di recente")
                .padding(.horizontal, 20)
            if viewModel.recentlyPlayedTracks.isEmpty {
                ZuneNote(text: "nessun brano recente")
                    .padding(.horizontal, 20)
            } else {
                let recent = Array(viewModel.recentlyPlayedTracks.prefix(10))
                ZuneStrip {
                    ForEach(recent) { track in
                        ZuneTrackTile(track: track, queue: recent, size: 140)
                    }
                }
            }

            ZuneSectionTitle(text: "album")
                .padding(.horizontal, 20)
            if recentAlbums.isEmpty {
                ZuneNote(text: "nessun album disponibile")
                    .padding(.horizontal, 20)
            } else {
                ZuneStrip {
                    ForEach(recentAlbums) { album in
                        ZuneAlbumTile(album: album, size: 140)
                    }
                }
            }
        }
        .refreshable {
            await viewModel.fetchAllLibraryData()
        }
        .task {
            await viewModel.fetchRecentlyPlayedAlbumsIfNeeded()
            await viewModel.fetchRecentlyAddedAlbumsIfNeeded()
            await viewModel.fetchRecentlyPlayedTracksIfNeeded()
        }
    }

    private func hero(_ item: AudioItem) -> some View {
        let isCurrent = viewModel.currentlyPlayingItem?.id == item.id
        let playing = isCurrent && viewModel.isPlaying

        return HStack(alignment: .bottom, spacing: 14) {
            CachedAsyncImage(url: viewModel.artworkURL(for: item.AlbumId ?? item.id, size: 300), targetSize: 110,
                content: { $0.resizable().aspectRatio(contentMode: .fill) },
                placeholder: { Rectangle().fill(.white.opacity(0.12)) }
            )
            .frame(width: 110, height: 110)
            .clipped()

            VStack(alignment: .leading, spacing: 3) {
                Text(item.Name.lowercased())
                    .font(.zune(26, .semilight, relativeTo: .title2))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text((viewModel.artistName(for: item) ?? "").lowercased())
                    .font(.zune(17, .regular, relativeTo: .subheadline))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                if isCurrent {
                    ClockReader(clock: viewModel.clock) { time in
                        Text("\(ZuneFormat.time(time)) / \(ZuneFormat.time(item.duration ?? 0))")
                            .font(.zune(14, .regular, relativeTo: .caption).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                ZuneCircleButton(title: playing ? "pausa" : "riproduci",
                                 systemImage: playing ? "pause.fill" : "play.fill") {
                    if isCurrent {
                        playing ? viewModel.playerManager.pause() : viewModel.playerManager.play()
                    } else {
                        viewModel.playerManager.play(item: item, in: viewModel.audioItems)
                    }
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Songs

/// Every song in one long lowercase list; the background follows the artist at the top.
struct ZuneTracksView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let tracks: [AudioItem]

    @State private var topRow = ZuneTopRowTracker()
    @State private var backdropTrack: AudioItem?

    var body: some View {
        ZuneScreen(title: "brani",
                   backdropURLs: backdropTrack.map { viewModel.artistImageURLs(for: $0) } ?? [],
                   scrolledID: topRow.binding { id in
                       backdropTrack = id.flatMap { id in tracks.first { $0.Id == id } } ?? backdropTrack
                   }) {
            HStack(spacing: 24) {
                Text("\(tracks.count) brani")
                    .font(.zune(17, .semilight, relativeTo: .subheadline))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                if !tracks.isEmpty {
                    ZuneCircleButton(title: "casuale", systemImage: "shuffle") {
                        viewModel.playerManager.playAlbumShuffled(tracks: tracks)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(tracks) { track in
                    ZuneTrackRow(track: track, queue: tracks, leading: .artwork)
                        .id(track.Id)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 20)
        }
        .refreshable {
            await viewModel.fetchAllLibraryData()
        }
        .onAppear {
            if backdropTrack == nil { backdropTrack = viewModel.currentlyPlayingItem ?? tracks.first }
        }
        .onChange(of: tracks.count) {
            if backdropTrack == nil { backdropTrack = tracks.first }
        }
    }
}

// MARK: - Albums

/// Grid of square covers; the background follows the album at the top.
struct ZuneAlbumsView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let albums: [AlbumItem]

    @State private var topRow = ZuneTopRowTracker()
    @State private var backdropAlbum: AlbumItem?
    @State private var gridWidth: CGFloat = 0

    private let minTile: CGFloat = 150
    private let spacing: CGFloat = 14

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(tileSize), spacing: spacing, alignment: .top), count: columnCount)
    }

    var body: some View {
        ZuneScreen(title: "album",
                   backdropURLs: backdropAlbum.map { viewModel.artistImageURLs(for: $0) } ?? [],
                   scrolledID: topRow.binding { id in
                       backdropAlbum = id.flatMap { id in albums.first { $0.Id == id } } ?? backdropAlbum
                   }) {
            if albums.isEmpty {
                ZuneNote(text: "nessun album trovato")
                    .padding(.horizontal, 20)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(albums) { album in
                        ZuneAlbumTile(album: album, size: tileSize)
                            .id(album.Id)
                    }
                }
                .scrollTargetLayout()
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                .padding(.horizontal, 20)
            }
        }
        .refreshable {
            await viewModel.fetchAllLibraryData()
        }
        .onAppear {
            if backdropAlbum == nil { backdropAlbum = albums.first }
        }
        .onChange(of: albums.count) {
            if backdropAlbum == nil { backdropAlbum = albums.first }
        }
    }

    /// As many columns as fit, each tile filling its column (two on a phone).
    private var columnCount: Int {
        guard gridWidth > 0 else { return 2 }
        return max(Int((gridWidth + spacing) / (minTile + spacing)), 1)
    }

    private var tileSize: CGFloat {
        guard gridWidth > 0 else { return minTile }
        let n = CGFloat(columnCount)
        return floor((gridWidth - spacing * (n - 1)) / n)
    }
}

// MARK: - Favorites

struct ZuneFavoritesView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    private var backdropURLs: [URL] {
        if let album = viewModel.favoriteAlbums.first { return viewModel.artistImageURLs(for: album) }
        if let track = viewModel.favoriteTracks.first { return viewModel.artistImageURLs(for: track) }
        return []
    }

    var body: some View {
        ZuneScreen(title: "preferiti", backdropURLs: backdropURLs) {
            sectionHeader("album", canClear: !viewModel.favoriteAlbumIds.isEmpty) {
                for id in viewModel.favoriteAlbumIds { viewModel.toggleFavoriteAlbum(id) }
            }
            if viewModel.favoriteAlbums.isEmpty {
                ZuneNote(text: "nessun album preferito")
                    .padding(.horizontal, 20)
            } else {
                ZuneStrip {
                    ForEach(viewModel.favoriteAlbums) { album in
                        ZuneAlbumTile(album: album)
                    }
                }
            }

            sectionHeader("brani", canClear: !viewModel.favoriteTrackIds.isEmpty) {
                for id in viewModel.favoriteTrackIds { viewModel.toggleFavoriteTrack(id) }
            }
            if viewModel.favoriteTracks.isEmpty {
                ZuneNote(text: "nessun brano preferito")
                    .padding(.horizontal, 20)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.favoriteTracks) { track in
                        ZuneTrackRow(track: track, queue: viewModel.favoriteTracks, leading: .artwork)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func sectionHeader(_ title: String, canClear: Bool, clear: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            ZuneSectionTitle(text: title)
            Spacer()
            if canClear {
                Button("rimuovi tutti", action: clear)
                    .font(.zune(16, .regular, relativeTo: .subheadline))
                    .foregroundStyle(.white.opacity(0.7))
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
    }
}
