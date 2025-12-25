import SwiftUI
import AppKit

struct HomeView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                FavoritesSectionSplit()

                ResumeNowSection()

                RecentTracksSection()

                RecentAlbumsSection()

                // Other sections here...
            }
            .padding()
        }
        .task {
            await viewModel.fetchRecentlyPlayedAlbumsIfNeeded()
            await viewModel.fetchRecentlyAddedAlbumsIfNeeded()
        }
    }
}

private struct FavoritesSectionSplit: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    private let albumColumns = [GridItem(.adaptive(minimum: 140), spacing: 12)]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preferiti")
                .font(.title2)
                .bold()
                .padding(.horizontal, 4)
            
            // Favorite albums
            VStack(alignment: .leading, spacing: 8) {
                Text("Album")
                    .font(.headline)
                    .padding(.horizontal, 4)
                
                if viewModel.favoriteAlbums.isEmpty {
                    Text("Nessun album preferito — tocca il cuore su un album per aggiungerlo.")
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
            
            // Favorite tracks
            VStack(alignment: .leading, spacing: 8) {
                Text("Brani")
                    .font(.headline)
                    .padding(.horizontal, 4)
                
                if viewModel.favoriteTracks.isEmpty {
                    Text("Nessun brano preferito — tocca il cuore su una traccia per aggiungerla.")
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

                                if viewModel.currentlyPlayingItem?.id == track.id {
                                    Image(systemName: viewModel.isPlaying ? "waveform" : "pause.circle")
                                        .foregroundColor(.accentColor)
                                }

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
        .padding(.horizontal, 4)
    }
}

private struct ResumeNowSection: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    // Scala applicata solo a questa sezione
    private let playScale: CGFloat = 1.5
    private var artworkResumeSize: CGFloat { 60 * playScale } // da 60 -> 90
    private var playButtonSize: CGFloat { 44 * playScale } // da 44 -> 66
    private var iconSize: CGFloat { 18 * playScale } // icona interna al bottone

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
                    .id(artworkURL)
                    .frame(width: artworkResumeSize, height: artworkResumeSize)
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

                    Button(action: {
                        handlePlayPause(for: item)
                    }) {
                        let isCurrent = (viewModel.currentlyPlayingItem?.id == item.id)
                        let playing = viewModel.isPlaying && isCurrent
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: iconSize))
                            .foregroundColor(.accentColor)
                            .frame(width: playButtonSize, height: playButtonSize)
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
            if viewModel.isPlaying {
                viewModel.playerManager.pause()
            } else {
                viewModel.playerManager.play()
            }
        } else {
            viewModel.playerManager.play(item: item, in: viewModel.audioItems)
        }
    }

    private var currentlyPlayingItem: AudioItem? {
        if let current = viewModel.currentlyPlayingItem {
            return current
        }
        return viewModel.audioItems.first
    }

    private var playbackPositionText: String? {
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

                            // Favorite button for track
                            Button(action: {
                                viewModel.toggleFavoriteTrack(track.id)
                            }) {
                                Image(systemName: viewModel.isTrackFavorite(track.id) ? "heart.fill" : "heart")
                                    .foregroundColor(viewModel.isTrackFavorite(track.id) ? .red : .secondary)
                            }
                            .buttonStyle(PlainButtonStyle())

                            if viewModel.currentlyPlayingItem?.id == track.id {
                                Image(systemName: viewModel.isPlaying ? "waveform" : "pause.circle")
                                    .foregroundColor(.accentColor)
                            }

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
        .padding(.horizontal, 4)
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
