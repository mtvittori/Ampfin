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

    @AppStorage(HomeStyle.storageKey) private var homeStyle = HomeStyle.classic.rawValue

    var body: some View {
        if colorManager.zuneStyleEnabled {
            ZuneHomeView()
        } else if homeStyle == HomeStyle.appleMusic.rawValue {
            AppleHomeView()
        } else {
            classicBody
        }
    }

    /// Cover whose colors tint the moving background: what's playing, else the latest.
    private var auroraURL: URL? {
        if let item = viewModel.currentlyPlayingItem ?? viewModel.recentlyPlayedTracks.first {
            return viewModel.artworkURL(for: item.AlbumId ?? item.id, size: 300)
        }
        return viewModel.recentlyAddedAlbums.first.map { viewModel.artworkURL(for: $0.id, size: 300) } ?? nil
    }

    private var classicBody: some View {
        ScrollView {
            VStack(spacing: 24) {
                FavoritesSectionSplit()
                    .entrance(.rise)

                ResumeNowSection()
                    .entrance(.rise, delay: 0.08)

                RecentTracksSection()
                    .entrance(.rise, delay: 0.16)

                RecentAlbumsSection()
                    .entrance(.rise, delay: 0.24)
            }
            .padding(.top, 16)
            // Room for the mini player above the tab bar.
            .padding(.bottom, 170)
        }
        .background {
            AuroraBackground(imageURL: auroraURL)
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
                            VerticalAlbumCard(album: album, cardWidth: 160, zoomGroup: "home-fav")
                                .coverFlow()
                        }
                        ForEach(viewModel.favoriteTracks) { track in
                            VerticalTrackCard(track: track, queue: viewModel.audioItems, cardWidth: 160)
                                .coverFlow()
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
    @ObservedObject private var colorManager = AccentColorManager.shared
    @State private var coverColor: Color = .clear

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
                        Text(viewModel.artistName(for: item) ?? "Artista Sconosciuto")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        // Only this line follows the playback clock.
                        ClockReader(clock: viewModel.clock) { _ in
                            if let positionText = playbackPositionText {
                                Text(positionText)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
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
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                }
                .padding(14)
                // A control, not just content: the whole card plays, so it is interactive
                // glass tinted with the cover, and it answers the finger.
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onTapGesture { handlePlayPause(for: item) }
                .glassEffect(.regular.tint(colorManager.glassTintEnabled
                                           ? coverColor.opacity(0.45 * colorManager.glassTintIntensity) : .clear)
                                 .interactive(),
                             in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .task(id: item.AlbumId ?? item.id) {
                    guard let url = viewModel.artworkURL(for: item.AlbumId ?? item.id, size: 120),
                          let image = await ZuneImageLoader.shared.firstImage(from: [url]),
                          let color = image.averageColor() else { return }
                    withAnimation(.easeInOut(duration: 0.6)) { coverColor = color }
                }
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
        return viewModel.recentlyPlayedTracks.first ?? viewModel.audioItems.first
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
                                .coverFlow()
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
                            VerticalAlbumCard(album: album, cardWidth: 160, zoomGroup: "home-recent")
                                .coverFlow()
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
                    Text(viewModel.artistName(for: track) ?? "Artista")
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
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: viewModel.isTrackFavorite(track.id))
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

    /// Disk read and color sampling off the main thread, so cards don't stall scrolling.
    private func loadAverageColor(url: URL?) async {
        guard let url else { return }
        let color = await Task.detached(priority: .utility) { () -> Color? in
            let key = ImageCacheService.shared.key(for: url)
            return ImageCacheService.shared.getImage(forKey: key)?.averageColor()
        }.value
        if let color {
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
    /// Keeps zoom ids unique when the same album shows in two strips.
    var zoomGroup: String = "card"

    @State private var avgColor: Color = .clear
    @State private var colorIsLight: Bool = false

    var body: some View {
        let artworkURL = viewModel.artworkURL(for: album.id, size: 300)
        let zoomID = "\(zoomGroup)-\(album.id)"

        NavigationLink(destination: AlbumTracksListView(album: album).zoomDestination(zoomID)) {
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
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.bounce, value: viewModel.isAlbumFavorite(album.id))
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
            .zoomSource(zoomID)
        }
        .buttonStyle(.pressable)
        .task(id: artworkURL) {
            await loadAverageColor(url: artworkURL)
        }
    }

    /// Disk read and color sampling off the main thread, so cards don't stall scrolling.
    private func loadAverageColor(url: URL?) async {
        guard let url else { return }
        let color = await Task.detached(priority: .utility) { () -> Color? in
            let key = ImageCacheService.shared.key(for: url)
            return ImageCacheService.shared.getImage(forKey: key)?.averageColor()
        }.value
        if let color {
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
                .contentTransition(.symbolEffect(.replace))
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
                Text(viewModel.artistName(for: track) ?? "Artista Sconosciuto")
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
