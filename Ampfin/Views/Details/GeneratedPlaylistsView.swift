// GeneratedPlaylistsView.swift
import SwiftUI

struct GeneratedPlaylistsView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @StateObject private var playlistVM: PlaylistViewModel

    init() {
        // inizializziamo con nil: assegneremo l'apiService reale in .task usando viewModel
        _playlistVM = StateObject(wrappedValue: PlaylistViewModel(apiService: nil))
    }

    var body: some View {
        List {
            if playlistVM.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if let error = playlistVM.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .padding()
            } else if playlistVM.playlists.isEmpty {
                Text("Nessuna playlist trovata.")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ForEach(playlistVM.playlists) { playlist in
                    playlistRow(playlist: playlist)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Playlist")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    Task {
                        await playlistVM.fetchPlaylists()
                    }
                }) {
                    Label("Aggiorna", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
            }
        }
        .task {
            // Assicuriamoci che PlaylistViewModel usi la stessa apiService del JellyfinViewModel
            // Non accediamo direttamente a `viewModel.apiService` perché è private nel ViewModel;
            // usiamo invece la factory pubblica che restituisce un PlaylistViewModel configurato.
            playlistVM.setAPIService(viewModel.makePlaylistViewModel().apiService)
            await playlistVM.fetchPlaylists()
        }
    }

    @ViewBuilder
    private func playlistRow(playlist: PlaylistItem) -> some View {
        HStack(spacing: 12) {
            // artwork: Jellyfin usa l'id della playlist per l'immagine principale delle playlist se disponibile
            let artworkURL = playlistVM.artworkURL(for: playlist.Id, size: 120)
            CachedAsyncImage(url: artworkURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(Color.gray.opacity(0.2)).overlay(Image(systemName: "music.note.list"))
            }
            .frame(width: 56, height: 56)
            .cornerRadius(6)

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.Name).font(.body).lineLimit(1)
                if let count = playlist.ItemCount {
                    Text("\(count) brani").font(.caption).foregroundColor(.secondary)
                }
            }

            Spacer()

            // Favorite button (salvato nel JellyfinViewModel)
            Button(action: {
                viewModel.toggleFavoritePlaylist(playlist.Id)
            }) {
                Image(systemName: viewModel.isPlaylistFavorite(playlist.Id) ? "heart.fill" : "heart")
                    .foregroundColor(viewModel.isPlaylistFavorite(playlist.Id) ? .red : .secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.trailing, 6)

            // Play button
            Button(action: {
                Task {
                    await playPlaylist(playlist)
                }
            }) {
                Image(systemName: "play.fill")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)

            // Shuffle button
            Button(action: {
                Task {
                    await shufflePlaylist(playlist)
                }
            }) {
                Image(systemName: "shuffle")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            // qui potresti aprire una view dettaglio playlist; per ora avviamo la riproduzione
            Task {
                await playPlaylist(playlist)
            }
        }
    }

    // MARK: - Actions

    private func playPlaylist(_ playlist: PlaylistItem) async {
        do {
            let items = try await playlistVM.fetchPlaylistItems(playlistId: playlist.Id)
            guard let first = items.first else { return }
            viewModel.playerManager.play(item: first, in: items)
        } catch {
            // Mostriamo errore semplice (puoi migliorare con alert)
            playlistVM.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func shufflePlaylist(_ playlist: PlaylistItem) async {
        do {
            let items = try await playlistVM.fetchPlaylistItems(playlistId: playlist.Id)
            viewModel.playerManager.playAlbumShuffled(tracks: items)
        } catch {
            playlistVM.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
