// In Views/Detail/ArtistAlbumsView.swift
import SwiftUI

struct ArtistAlbumsView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var colorManager = AccentColorManager.shared
    let artist: ArtistItem

    private var filteredAlbums: [AlbumItem] {
        viewModel.albums.filter { $0.AlbumArtist == artist.Name }
    }

    var body: some View {
        if colorManager.zuneStyleEnabled {
            zunePage
        } else {
            classicGrid
        }
    }

    private var classicGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 20)]) {
                ForEach(filteredAlbums) { album in
                    let artworkURL = viewModel.artworkURL(for: album.id, size: 300)
                    NavigationLink(destination: AlbumTracksListView(album: album)) {
                        AlbumGridItemView(album: album, artworkURL: artworkURL)
                            .drawingGroup()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(.clear) // Aggiungi anche qui!
        .navigationTitle(artist.Name)
    }

    // MARK: - Zune

    /// The photo fills the screen and pans; the name sits low and runs off the edge,
    /// with albums and songs scrolling up over the photo.
    private var zunePage: some View {
        let tracks = viewModel.tracks(byArtist: artist)

        return GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: geo.size.height * 0.34)

                    ZuneOverflowText(text: artist.Name, size: 84)
                        .padding(.leading, 16)

                    if let genres = artist.Genres, !genres.isEmpty {
                        Text(genres.prefix(3).joined(separator: " · ").lowercased())
                            .font(.zune(17, .semilight, relativeTo: .subheadline))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 20)
                    }

                    if !tracks.isEmpty {
                        HStack(spacing: 28) {
                            ZuneCircleButton(title: "riproduci", systemImage: "play.fill") {
                                viewModel.playerManager.play(item: tracks[0], in: tracks)
                            }
                            ZuneCircleButton(title: "casuale", systemImage: "shuffle") {
                                viewModel.playerManager.playAlbumShuffled(tracks: tracks)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                    }

                    if !filteredAlbums.isEmpty {
                        ZuneSectionTitle(text: "album")
                            .padding(.horizontal, 20)
                        ZuneStrip {
                            ForEach(filteredAlbums) { album in
                                ZuneAlbumTile(album: album, showsArtist: false)
                            }
                        }
                    }

                    if !tracks.isEmpty {
                        ZuneSectionTitle(text: "brani")
                            .padding(.horizontal, 20)
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(tracks) { track in
                                ZuneTrackRow(track: track, queue: tracks, detail: .album)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.bottom, 140)
            }
            #if os(iOS)
            .hidesMiniPlayerOnScroll()
            #endif
        }
        .background {
            ZuneBackdrop(urls: viewModel.artistImageURLs(for: artist), dim: 0.35)
                .ignoresSafeArea()
        }
        .zuneChrome()
    }
}
