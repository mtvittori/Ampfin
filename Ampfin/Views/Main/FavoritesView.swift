import SwiftUI

struct FavoritesView: View {
    @ObservedObject private var colorManager = AccentColorManager.shared
    @EnvironmentObject var viewModel: JellyfinViewModel

    var body: some View {
        if colorManager.zuneStyleEnabled {
            ZuneFavoritesView()
        } else {
            classicBody
        }
    }

    private var classicBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Favorite Albums
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Album preferiti")
                            .font(.title2)
                            .bold()
                        Spacer()
                        if !viewModel.favoriteAlbumIds.isEmpty {
                            Button(action: {
                                for id in viewModel.favoriteAlbumIds {
                                    viewModel.toggleFavoriteAlbum(id)
                                }
                            }) {
                                Label("Rimuovi tutti", systemImage: "trash")
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                    }

                    if viewModel.favoriteAlbums.isEmpty {
                        Text("Nessun album preferito.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.vertical)
                            .frame(maxWidth: .infinity)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(viewModel.favoriteAlbums) { album in
                                    VerticalAlbumCard(album: album, cardWidth: 160, zoomGroup: "favorites")
                                        .coverFlow()
                                }
                            }
                        }
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
                                for id in viewModel.favoriteTrackIds {
                                    viewModel.toggleFavoriteTrack(id)
                                }
                            }) {
                                Label("Rimuovi tutti", systemImage: "trash")
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                    }

                    if viewModel.favoriteTracks.isEmpty {
                        Text("Nessun brano preferito.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.vertical)
                            .frame(maxWidth: .infinity)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(viewModel.favoriteTracks) { track in
                                    VerticalTrackCard(track: track, queue: viewModel.audioItems, cardWidth: 160)
                                        .coverFlow()
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 170)
        }
        .navigationTitle("Preferiti")
    }
}
