// In Views/Detail/ArtistAlbumsView.swift
import SwiftUI

struct ArtistAlbumsView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let artist: ArtistItem

    private var filteredAlbums: [AlbumItem] {
        viewModel.albums(byArtist: artist)
    }

    var body: some View {
        #if os(macOS)
        MacArtistPage(artist: artist)
        #else
        phoneBody
        #endif
    }

    private var phoneBody: some View {
        page
        .sheet(item: $infoTrack) { track in
            ItemInfoSheet(itemId: track.Id, kind: .track, title: track.Name)
                .environmentObject(viewModel)
        }
    }

    @State private var showAllTracks = false
    @State private var infoTrack: AudioItem?

    /// Apple Music-style page: the artist's photo edge to edge, fading into its color;
    /// top songs, then the albums as a strip of covers.
    private var page: some View {
        let tracks = viewModel.tracks(byArtist: artist)
        let trackIds = Set(tracks.map(\.Id))
        let isCurrent = viewModel.currentlyPlayingItem.map { trackIds.contains($0.Id) } ?? false
        let shown = showAllTracks ? tracks : Array(tracks.prefix(5))

        return HeroPage(
            // The portrait suits the square header better than the wide backdrop.
            imageURLs: viewModel.artistImageURLs(for: artist, maxWidth: 1200).reversed()
                + filteredAlbums.prefix(1).compactMap { viewModel.artworkURL(for: $0.id, size: 1200) },
            title: artist.Name,
            subtitle: artist.Genres?.prefix(2).joined(separator: " · "),
            details: artistDetails(albums: filteredAlbums.count, tracks: tracks.count)
        ) { palette in
            HeroPlayControls(
                palette: palette,
                isCurrent: isCurrent,
                isPlaying: viewModel.isPlaying,
                isFavorite: nil,
                onPlay: {
                    if let first = tracks.first { viewModel.playerManager.play(item: first, in: tracks) }
                },
                onShuffle: { viewModel.playerManager.playAlbumShuffled(tracks: tracks) },
                onTogglePause: {
                    viewModel.isPlaying ? viewModel.playerManager.pause() : viewModel.playerManager.play()
                },
                onFavorite: {}
            )
        } content: { palette in
            if !tracks.isEmpty {
                heroSection("Brani", palette: palette)
                LazyVStack(spacing: 0) {
                    ForEach(shown) { track in
                        HeroTrackRow(track: track, number: nil, detail: track.Album,
                                     queue: tracks, palette: palette,
                                     onInfo: { infoTrack = $0 })
                    }
                }
                .padding(.horizontal, 20)

                if tracks.count > 5 {
                    Button(showAllTracks ? "Mostra meno" : "Mostra tutti (\(tracks.count))") {
                        withAnimation(.soft(0.4)) { showAllTracks.toggle() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                }
            }

            if !filteredAlbums.isEmpty {
                heroSection("Album", palette: palette)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(filteredAlbums) { album in
                            heroAlbumTile(album, palette: palette)
                                .coverFlow()
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollClipDisabled()
            }
        }
    }

    private func heroSection(_ title: String, palette: HeroPalette) -> some View {
        Text(title)
            .font(.title3.weight(.bold))
            .foregroundStyle(palette.foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private func heroAlbumTile(_ album: AlbumItem, palette: HeroPalette) -> some View {
        let zoomID = "artist-\(album.id)"
        return NavigationLink(destination: AlbumTracksListView(album: album).zoomDestination(zoomID)) {
            VStack(alignment: .leading, spacing: 4) {
                CachedAsyncImage(url: viewModel.artworkURL(for: album.id, size: 400), targetSize: 160,
                    content: { $0.resizable().aspectRatio(contentMode: .fill) },
                    placeholder: { RoundedRectangle(cornerRadius: 10).fill(palette.foreground.opacity(0.12)) }
                )
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .zoomSource(zoomID)

                Text(album.Name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                if let year = album.ProductionYear {
                    Text(String(year))
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                }
            }
            .frame(width: 160, alignment: .leading)
        }
        .buttonStyle(.pressable)
    }

    private func artistDetails(albums: Int, tracks: Int) -> String {
        var parts: [String] = []
        if albums > 0 { parts.append(albums == 1 ? "1 album" : "\(albums) album") }
        if tracks > 0 { parts.append(tracks == 1 ? "1 brano" : "\(tracks) brani") }
        return parts.joined(separator: " · ")
    }
}
