import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    private let albumColumns = [GridItem(.adaptive(minimum: 140), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Favorite Albums
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Album preferiti")
                            .font(.title2)
                            .bold()
                        Spacer()
                        if !viewModel.favoriteAlbumIds.isEmpty {
                            Button(action: {
                                // Clear album favorites
                                for id in viewModel.favoriteAlbumIds {
                                    viewModel.toggleFavoriteAlbum(id)
                                }
                            }) {
                                Label("Rimuovi tutti", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 4)

                    if viewModel.favoriteAlbums.isEmpty {
                        Text("Nessun album preferito.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(8)
                    } else {
                        LazyVGrid(columns: albumColumns, spacing: 12) {
                            ForEach(viewModel.favoriteAlbums) { album in
                                let artworkURL = viewModel.artworkURL(for: album.id, size: 300)
                                NavigationLink(destination: AlbumTracksListView(album: album)) {
                                    AlbumGridItemView(album: album, artworkURL: artworkURL)
                                        .frame(minWidth: 140, minHeight: 160)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }

                // Favorite Tracks
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Brani preferiti")
                            .font(.title2)
                            .bold()
                        Spacer()
                        if !viewModel.favoriteTrackIds.isEmpty {
                            Button(action: {
                                // Clear track favorites
                                for id in viewModel.favoriteTrackIds {
                                    viewModel.toggleFavoriteTrack(id)
                                }
                            }) {
                                Label("Rimuovi tutti", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 4)

                    if viewModel.favoriteTracks.isEmpty {
                        Text("Nessun brano preferito.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(8)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(viewModel.favoriteTracks) { track in
                                HStack(spacing: 10) {
                                    CachedAsyncImage(url: viewModel.artworkURL(for: track.AlbumId ?? track.id, size: 80)) { image in
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    } placeholder: {
                                        Rectangle().fill(Color.gray.opacity(0.2)).overlay(Image(systemName: "music.note"))
                                    }
                                    .frame(width: 48, height: 48)
                                    .cornerRadius(6)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.Name).font(.subheadline).lineLimit(1)
                                        Text(track.mainArtistName ?? "Artista Sconosciuto")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()

                                    Button(action: {
                                        viewModel.toggleFavoriteTrack(track.id)
                                    }) {
                                        Image(systemName: viewModel.isTrackFavorite(track.id) ? "heart.fill" : "heart")
                                            .foregroundColor(viewModel.isTrackFavorite(track.id) ? .red : .secondary)
                                    }
                                    .buttonStyle(PlainButtonStyle())

                                    Button(action: {
                                        let isCurrent = (viewModel.currentlyPlayingItem?.id == track.id)
                                        if isCurrent {
                                            if viewModel.isPlaying {
                                                viewModel.playerManager.pause()
                                            } else {
                                                viewModel.playerManager.play()
                                            }
                                        } else {
                                            viewModel.playerManager.play(item: track, in: viewModel.audioItems)
                                        }
                                    }) {
                                        let isCurrent = (viewModel.currentlyPlayingItem?.id == track.id)
                                        let playing = viewModel.isPlaying && isCurrent
                                        Image(systemName: playing ? "pause.fill" : "play.fill")
                                            .foregroundColor(.accentColor)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                                .padding(8)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(8)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Preferiti")
    }
}
