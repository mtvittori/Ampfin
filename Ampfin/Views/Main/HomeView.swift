import SwiftUI

// MARK: - Content-layer scrim helper
//
// HIG: "Don't use Liquid Glass in the content layer" — cards scrolling among other
// content should use a standard Material for legibility, not a custom `.glassEffect()`.
// Liquid Glass stays reserved for the transport button in these cards (a real control).
private extension View {
    func cardScrim(tint: Color, tintEnabled: Bool, cornerRadius: CGFloat) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    if tintEnabled {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(tint.opacity(0.35 * AccentColorManager.shared.glassTintIntensity))
                    }
                }
        }
    }
}

struct HomeView: View {
    @ObservedObject private var colorManager = AccentColorManager.shared
    @EnvironmentObject var viewModel: JellyfinViewModel

    var body: some View {
        if colorManager.zuneStyleEnabled {
            ZuneHomeView()
        } else {
            classicBody
        }
    }

    private var classicBody: some View {
        ScrollView {
            VStack(spacing: 24) {
                FavoritesSectionSplit()

                ResumeNowSection()

                RecentTracksSection()

                RecentAlbumsSection()
            }
            .padding(.top, 16)
            .padding(.bottom, 80)
        }
        #if os(iOS)
        .hidesMiniPlayerOnScroll()
        #endif
        .refreshable {
            await viewModel.fetchAllLibraryData()
        }
        .task {
            await viewModel.fetchRecentlyPlayedAlbumsIfNeeded()
            await viewModel.fetchRecentlyAddedAlbumsIfNeeded()
            await viewModel.fetchRecentlyPlayedTracksIfNeeded()
        }
    }
}

// MARK: - Favorites Section

private struct FavoritesSectionSplit: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preferiti")
                .font(.title2)
                .bold()
                .padding(.horizontal, 16)
            
            if viewModel.favoriteAlbums.isEmpty && viewModel.favoriteTracks.isEmpty {
                Text("Nessun preferito — tocca il cuore su un album o brano per aggiungerlo.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(viewModel.favoriteAlbums) { album in
                            VerticalAlbumCard(album: album, cardWidth: 160)
                        }
                        ForEach(viewModel.favoriteTracks) { track in
                            VerticalTrackCard(track: track, queue: viewModel.audioItems, cardWidth: 160)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollClipDisabled()
            }
        }
    }
}

// MARK: - Resume Now Section

private struct ResumeNowSection: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Riprendi da dove hai lasciato")
                .font(.title2)
                .bold()
                .frame(maxWidth: .infinity, alignment: .leading)

            if let item = currentlyPlayingItem {
                HStack(spacing: 14) {
                    let artworkURL = viewModel.artworkURL(for: item.AlbumId ?? item.id, size: 120)
                    CachedAsyncImage(url: artworkURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(Color.gray.opacity(0.2)).overlay(Image(systemName: "music.note"))
                    }
                    .id(artworkURL)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

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
                            .font(.title2)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                Text("Nessun brano da riprendere")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }
        }
        .padding(.horizontal, 16)
    }

    private func handlePlayPause(for item: AudioItem) {
        let isCurrent = (viewModel.currentlyPlayingItem?.id == item.id)
        if isCurrent {
            if viewModel.isPlaying { viewModel.playerManager.pause() }
            else { viewModel.playerManager.play() }
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

// MARK: - Recent Tracks Section

private struct RecentTracksSection: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    private let maxItems = 10

    private var tracks: [AudioItem] {
        Array(viewModel.recentlyPlayedTracks.prefix(maxItems))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ultime canzoni ascoltate")
                .font(.title2)
                .bold()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)

            if tracks.isEmpty {
                Text("Nessuna traccia recente")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(tracks) { track in
                            VerticalTrackCard(track: track, queue: viewModel.audioItems, cardWidth: 160)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollClipDisabled()
            }
        }
    }
}

// MARK: - Recent Albums Section

private struct RecentAlbumsSection: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    private let maxAlbums = 12

    private var albumsToShow: [AlbumItem] {
        // Actual listening activity wins over "recently added to the library" —
        // otherwise this section never reflects what you've played (see viewModel.recentlyPlayedAlbums).
        if !viewModel.recentlyPlayedAlbums.isEmpty {
            return Array(viewModel.recentlyPlayedAlbums.prefix(maxAlbums))
        } else if !viewModel.recentlyAddedAlbums.isEmpty {
            return Array(viewModel.recentlyAddedAlbums.prefix(maxAlbums))
        } else {
            return Array(viewModel.albums.prefix(maxAlbums))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ultimi album")
                .font(.title2)
                .bold()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)

            if albumsToShow.isEmpty {
                Text("Nessun album disponibile")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(albumsToShow) { album in
                            VerticalAlbumCard(album: album, cardWidth: 160)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollClipDisabled()
            }
        }
    }
}

// MARK: - Vertical Track Card (artwork + colored background + controls)

struct VerticalTrackCard: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var colorManager = AccentColorManager.shared
    let track: AudioItem
    let queue: [AudioItem]
    let cardWidth: CGFloat

    @State private var avgColor: Color = .clear
    @State private var colorIsLight: Bool = false

    var body: some View {
        let artworkURL = viewModel.artworkURL(for: track.AlbumId ?? track.id, size: 300)

        ZStack(alignment: .bottom) {
            // Artwork fills entire card
            CachedAsyncImage(url: artworkURL, targetSize: 300) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(Color.gray.opacity(0.2))
                    .overlay(Image(systemName: "music.note").foregroundColor(.secondary))
            }
            .frame(width: cardWidth, height: cardWidth)
            .clipped()

            // Liquid glass overlay with controls
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.Name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .foregroundColor(colorIsLight ? .black : .primary)
                    Text(track.mainArtistName ?? "Artista")
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundColor(colorIsLight ? .black.opacity(0.6) : .secondary)
                }

                Spacer()

                // Favorite
                Button {
                    viewModel.toggleFavoriteTrack(track.id)
                } label: {
                    Image(systemName: viewModel.isTrackFavorite(track.id) ? "heart.fill" : "heart")
                        .foregroundColor(viewModel.isTrackFavorite(track.id) ? .red : (colorIsLight ? .black : .primary))
                        .font(.callout)
                }
                .buttonStyle(.plain)

                // Play
                PlayButtonForTrack(track: track, queue: queue, colorIsLight: colorIsLight)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .cardScrim(tint: avgColor, tintEnabled: colorManager.glassTintEnabled, cornerRadius: 10)
            .padding(4)
        }
        .frame(width: cardWidth, height: cardWidth)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: artworkURL) {
            await loadAverageColor(url: artworkURL)
        }
    }

    private func loadAverageColor(url: URL?) async {
        guard let url else { return }
        let key = ImageCacheService.shared.key(for: url)
        if let cached = ImageCacheService.shared.getImage(forKey: key),
           let color = cached.averageColor() {
            avgColor = color
            colorIsLight = color.isLight()
        }
    }
}

// MARK: - Vertical Album Card (artwork + colored background + controls)

struct VerticalAlbumCard: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var colorManager = AccentColorManager.shared
    let album: AlbumItem
    let cardWidth: CGFloat

    @State private var avgColor: Color = .clear
    @State private var colorIsLight: Bool = false

    var body: some View {
        let artworkURL = viewModel.artworkURL(for: album.id, size: 300)

        NavigationLink(destination: AlbumTracksListView(album: album)) {
            ZStack(alignment: .bottom) {
                // Artwork fills entire card
                CachedAsyncImage(url: artworkURL, targetSize: 300) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.gray.opacity(0.2))
                        .overlay(Image(systemName: "music.note").font(.title).foregroundColor(.secondary))
                }
                .frame(width: cardWidth, height: cardWidth)
                .clipped()

                // Liquid glass overlay with info + favorite
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.Name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .foregroundColor(colorIsLight ? .black : .primary)
                        Text(album.AlbumArtist ?? "Artista")
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundColor(colorIsLight ? .black.opacity(0.6) : .secondary)
                    }

                    Spacer()

                    Button {
                        viewModel.toggleFavoriteAlbum(album.id)
                    } label: {
                        Image(systemName: viewModel.isAlbumFavorite(album.id) ? "heart.fill" : "heart")
                            .foregroundColor(viewModel.isAlbumFavorite(album.id) ? .red : (colorIsLight ? .black : .primary))
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .cardScrim(tint: avgColor, tintEnabled: colorManager.glassTintEnabled, cornerRadius: 10)
                .padding(4)
            }
            .frame(width: cardWidth, height: cardWidth)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .task(id: artworkURL) {
            await loadAverageColor(url: artworkURL)
        }
    }

    private func loadAverageColor(url: URL?) async {
        guard let url else { return }
        let key = ImageCacheService.shared.key(for: url)
        if let cached = ImageCacheService.shared.getImage(forKey: key),
           let color = cached.averageColor() {
            avgColor = color
            colorIsLight = color.isLight()
        }
    }
}

// MARK: - Play Button (isolated to prevent closure capture issues in LazyHStack)

private struct PlayButtonForTrack: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let track: AudioItem
    let queue: [AudioItem]
    var colorIsLight: Bool = false

    private var isCurrent: Bool {
        viewModel.currentlyPlayingItem?.id == track.id
    }

    private var isTrackPlaying: Bool {
        viewModel.isPlaying && isCurrent
    }

    var body: some View {
        Button {
            if isCurrent {
                isTrackPlaying ? viewModel.playerManager.pause() : viewModel.playerManager.play()
            } else {
                viewModel.playerManager.play(item: track, in: queue)
            }
        } label: {
            Image(systemName: isTrackPlaying ? "pause.fill" : "play.fill")
                .font(.body)
                .foregroundColor(colorIsLight ? .black : .primary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Legacy Track Card Row (horizontal, for backward compat)

struct TrackCardRow: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let track: AudioItem
    let queue: [AudioItem]

    var body: some View {
        HStack(spacing: 10) {
            CachedAsyncImage(url: viewModel.artworkURL(for: track.AlbumId ?? track.id, size: 80)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(Color.gray.opacity(0.2)).overlay(Image(systemName: "music.note"))
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.Name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(track.mainArtistName ?? "Artista Sconosciuto")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()

            // Favorite
            Button(action: {
                viewModel.toggleFavoriteTrack(track.id)
            }) {
                Image(systemName: viewModel.isTrackFavorite(track.id) ? "heart.fill" : "heart")
                    .foregroundColor(viewModel.isTrackFavorite(track.id) ? .red : .secondary)
            }
            .buttonStyle(.plain)

            // Downloaded indicator
            if DownloadManager.shared.isDownloaded(track.Id) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.accentColor)
                    .font(.caption)
            }

            // Now playing indicator
            if viewModel.currentlyPlayingItem?.id == track.id {
                Image(systemName: viewModel.isPlaying ? "waveform" : "pause.circle")
                    .foregroundColor(.accentColor)
                    .font(.caption)
            }

            // Play/Pause
            Button(action: {
                let isCurrent = (viewModel.currentlyPlayingItem?.id == track.id)
                if isCurrent {
                    if viewModel.isPlaying {
                        viewModel.playerManager.pause()
                    } else {
                        viewModel.playerManager.play()
                    }
                } else {
                    viewModel.playerManager.play(item: track, in: queue)
                }
            }) {
                let isCurrent = (viewModel.currentlyPlayingItem?.id == track.id)
                let playing = viewModel.isPlaying && isCurrent
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
