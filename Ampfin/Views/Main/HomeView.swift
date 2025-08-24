import SwiftUI
import AppKit

struct HomeView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ResumeNowSection()

                RecentTracksSection()

                RecentAlbumsSection()

                // Other sections here...
            }
            .padding()
        }
        .task {
            // Use the "ifNeeded" helpers that include caching checks
            await viewModel.fetchRecentlyPlayedAlbumsIfNeeded()
            await viewModel.fetchRecentlyAddedAlbumsIfNeeded()
            // Note: recently played tracks endpoint not implemented — RecentTracksSection uses a fallback.
        }
    }
}

private struct ResumeNowSection: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Riprendi da dove hai lasciato")
                .font(.title2)
                .bold()
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let item = currentlyPlayingItem {
                HStack(spacing: 12) {
                    let artworkURL = viewModel.artworkURL(for: item.AlbumId ?? item.id, size: 80)
                    CachedAsyncImage(url: artworkURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(Color.gray.opacity(0.2)).overlay(Image(systemName: "music.note"))
                    }
                    .id(artworkURL) // forza il refresh quando cambia l'URL
                    .frame(width: 60, height: 60)
                    .cornerRadius(6)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.Name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(item.mainArtistName ?? "Artista Sconosciuto")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        if let positionText = playbackPositionText {
                            Text(positionText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()

                    // Play / Pause toggle button:
                    Button(action: {
                        handlePlayPause(for: item)
                    }) {
                        // If the shown item is the currently playing one and playback is active, show Pause
                        let isCurrent = (viewModel.currentlyPlayingItem?.id == item.id)
                        let playing = viewModel.isPlaying && isCurrent
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                            .frame(width: 44, height: 44)
                            .background(Color.accentColor.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)
            } else {
                Text("Nessun brano da riprendere")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(12)
            }
        }
    }

    private func handlePlayPause(for item: AudioItem) {
        let isCurrent = (viewModel.currentlyPlayingItem?.id == item.id)
        if isCurrent {
            // If this is the current item, toggle play/pause
            if viewModel.isPlaying {
                viewModel.playerManager.pause()
            } else {
                // Resume existing item without re-creating queue
                viewModel.playerManager.play()
            }
        } else {
            // Start playback of this item within the app-wide queue
            viewModel.playerManager.play(item: item, in: viewModel.audioItems)
        }
    }

    private var currentlyPlayingItem: AudioItem? {
        // Prefer the actual playing item from the player (if any)
        if let current = viewModel.currentlyPlayingItem {
            return current
        }

        // Fallback: show the first available audio item
        return viewModel.audioItems.first
    }

    private var playbackPositionText: String? {
        // Only show playback position when the item displayed is the actual currently playing item
        guard let playing = viewModel.currentlyPlayingItem else { return nil }
        guard let displayed = currentlyPlayingItem, playing.id == displayed.id else { return nil }

        let position = viewModel.currentTime
        let minutes = Int(position) / 60
        let seconds = Int(position) % 60
        return "Riprendi da \(String(format: "%d:%02d", minutes, seconds))"
    }
}


/// Recent tracks section (fallback uses the first N audioItems if there's no dedicated recently-played endpoint)
private struct RecentTracksSection: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    private let maxItems = 8

    private var tracks: [AudioItem] {
        // Fallback: if you later add a `recentlyPlayedTracks` to the ViewModel, replace this with that property.
        Array(viewModel.audioItems.prefix(maxItems))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ultime canzoni ascoltate")
                .font(.title2)
                .bold()
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)

            if tracks.isEmpty {
                Text("Nessuna traccia recente")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
            } else {
                VStack(spacing: 8) {
                    ForEach(tracks) { track in
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

                            if viewModel.currentlyPlayingItem?.id == track.id {
                                // Indicate currently playing
                                Image(systemName: viewModel.isPlaying ? "waveform" : "pause.circle")
                                    .foregroundColor(.accentColor)
                            }

                            Button(action: {
                                handlePlay(for: track)
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
        .padding(.horizontal, 4)
    }

    private func handlePlay(for track: AudioItem) {
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
    }
}


/// Recent albums section — now prefers recentlyAddedAlbums, falls back to recentlyPlayedAlbums then general albums
private struct RecentAlbumsSection: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]
    private let maxAlbums = 12

    private var albumsToShow: [AlbumItem] {
        if !viewModel.recentlyAddedAlbums.isEmpty {
            return Array(viewModel.recentlyAddedAlbums.prefix(maxAlbums))
        } else if !viewModel.recentlyPlayedAlbums.isEmpty {
            return Array(viewModel.recentlyPlayedAlbums.prefix(maxAlbums))
        } else {
            return Array(viewModel.albums.prefix(maxAlbums))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ultimi album")
                .font(.title2)
                .bold()
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)

            if albumsToShow.isEmpty {
                Text("Nessun album disponibile")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(albumsToShow) { album in
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
        .padding(.horizontal, 4)
    }
}
