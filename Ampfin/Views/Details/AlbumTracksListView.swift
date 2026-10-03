import SwiftUI

struct AlbumTracksListView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var downloadManager = DownloadManager.shared
    let album: AlbumItem

    @State private var selectedTrackForInfo: AudioItem?
    @State private var showAlbumInfo = false
    @State private var showCoverPicker = false
    /// Rows cascade in only while the page opens, not when scrolled back into view.
    @State private var introRunning = true
    @ObservedObject private var colorManager = AccentColorManager.shared

    var body: some View {
        Group {
            if colorManager.zuneStyleEnabled {
                zuneBody
            } else {
                classicBody
            }
        }
        .task {
            await viewModel.fetchAlbumTracks(albumId: album.id)
        }
        .sheet(item: $selectedTrackForInfo) { track in
            ItemInfoSheet(itemId: track.Id, kind: .track, title: track.Name)
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showAlbumInfo) {
            ItemInfoSheet(itemId: album.Id, kind: .album, title: album.Name)
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showCoverPicker) {
            AlbumCoverPicker(album: album)
                .environmentObject(viewModel)
        }
    }

    // MARK: - Zune

    /// The album artist's photo behind a small square cover, the album name huge
    /// and running off the edge, then the numbered songs.
    private var zuneBody: some View {
        let tracks = viewModel.selectedAlbumTracks
        let artist = viewModel.artist(named: album.AlbumArtist)
        let totalTime = tracks.compactMap(\.duration).reduce(0, +)

        return GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: geo.size.height * 0.22)

                    CachedAsyncImage(url: viewModel.artworkURL(for: album.id, size: 400), targetSize: 150,
                        content: { $0.resizable().aspectRatio(contentMode: .fill) },
                        placeholder: { Rectangle().fill(.white.opacity(0.12)) }
                    )
                    .frame(width: 150, height: 150)
                    .clipped()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)

                    ZuneOverflowText(text: album.Name, size: 64)
                        .padding(.leading, 16)

                    if let artist {
                        NavigationLink(destination: ArtistAlbumsView(artist: artist)) {
                            artistLine
                        }
                        .buttonStyle(.plain)
                    } else {
                        artistLine
                    }

                    Text(albumFacts(trackCount: tracks.count, totalTime: totalTime))
                        .font(.zune(15, .regular, relativeTo: .caption))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 20)
                        .padding(.top, 4)

                    zuneActions(tracks)
                        .padding(.horizontal, 20)
                        .padding(.top, 22)

                    ZuneSectionTitle(text: "brani")
                        .padding(.horizontal, 20)

                    if viewModel.isLoadingAlbum {
                        ProgressView()
                            .tint(.white)
                            .padding(.horizontal, 20)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                ZuneTrackRow(track: track, queue: tracks, leading: .number(index + 1),
                                             detail: .artist,
                                             onInfo: { selectedTrackForInfo = $0 })
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
            ZuneBackdrop(urls: viewModel.artistImageURLs(for: album), dim: 0.45)
                .ignoresSafeArea()
        }
        .zuneChrome()
    }

    private var artistLine: some View {
        Text((album.AlbumArtist ?? "artista sconosciuto").lowercased())
            .font(.zune(22, .regular, relativeTo: .title3))
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
            .padding(.horizontal, 20)
    }

    private func albumFacts(trackCount: Int, totalTime: TimeInterval) -> String {
        var parts: [String] = []
        if let year = album.ProductionYear { parts.append(String(year)) }
        if trackCount > 0 { parts.append(trackCount == 1 ? "1 brano" : "\(trackCount) brani") }
        if totalTime > 0 { parts.append("\(Int((totalTime / 60).rounded())) min") }
        return parts.joined(separator: " · ")
    }

    private func zuneActions(_ tracks: [AudioItem]) -> some View {
        let allDownloaded = !tracks.isEmpty && tracks.allSatisfy { downloadManager.isDownloaded($0.Id) }

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ZuneCircleButton(title: "riproduci", systemImage: "play.fill") {
                    if let first = tracks.first {
                        viewModel.playerManager.play(item: first, in: tracks)
                    }
                }
                ZuneCircleButton(title: "casuale", systemImage: "shuffle") {
                    viewModel.playerManager.playAlbumShuffled(tracks: tracks)
                }
                ZuneCircleButton(systemImage: viewModel.isAlbumFavorite(album.id) ? "heart.fill" : "heart") {
                    viewModel.toggleFavoriteAlbum(album.id)
                }
                .accessibilityLabel(viewModel.isAlbumFavorite(album.id) ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti")
                ZuneCircleButton(systemImage: viewModel.repeatMode.iconName,
                                 tint: viewModel.repeatMode == .off ? .white : .accentColor) {
                    viewModel.toggleRepeatMode()
                }
                .accessibilityLabel("Ripeti")
                ZuneCircleButton(systemImage: allDownloaded ? "arrow.down.circle.fill" : "arrow.down") {
                    if allDownloaded {
                        for track in tracks { viewModel.removeDownload(for: track.Id) }
                    } else {
                        for track in tracks where !downloadManager.isDownloaded(track.Id) {
                            viewModel.downloadTrack(track)
                        }
                    }
                }
                .accessibilityLabel(allDownloaded ? "Rimuovi download" : "Scarica album")
                ZuneCircleButton(systemImage: "photo") {
                    showCoverPicker = true
                }
                .accessibilityLabel("Cambia copertina")
            }
        }
        .scrollClipDisabled()
    }

    // MARK: - Classic

    /// Apple Music-style page: the cover edge to edge, fading into its own color.
    private var classicBody: some View {
        let tracks = viewModel.selectedAlbumTracks
        let artist = viewModel.artist(named: album.AlbumArtist)

        return HeroPage(
            imageURLs: [viewModel.artworkURL(for: album.id, size: 1200)].compactMap { $0 },
            title: album.Name,
            subtitle: album.AlbumArtist,
            subtitleDestination: artist.map { AnyView(ArtistAlbumsView(artist: $0)) },
            details: classicDetails(tracks)
        ) { palette in
            HeroPlayControls(
                palette: palette,
                isCurrent: albumIsCurrent,
                isPlaying: viewModel.isPlaying,
                isFavorite: viewModel.isAlbumFavorite(album.id),
                onPlay: {
                    if let first = tracks.first { viewModel.playerManager.play(item: first, in: tracks) }
                },
                onShuffle: { viewModel.playerManager.playAlbumShuffled(tracks: tracks) },
                onTogglePause: {
                    viewModel.isPlaying ? viewModel.playerManager.pause() : viewModel.playerManager.play()
                },
                onFavorite: { viewModel.toggleFavoriteAlbum(album.id) }
            )
        } content: { palette in
            if viewModel.isLoadingAlbum {
                ProgressView()
                    .padding(.top, 20)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        HeroTrackRow(track: track,
                                     number: index + 1,
                                     detail: trackArtistIfDifferent(track),
                                     queue: tracks,
                                     palette: palette,
                                     onInfo: { selectedTrackForInfo = $0 })
                            .entrance(.slide, delay: 0.15 + Double(index) * 0.035, enabled: introRunning && index < 14)
                    }
                }
                .padding(.horizontal, 20)

                Text(classicFooter(tracks))
                    .font(.footnote)
                    .foregroundStyle(palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                albumMenu(tracks)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(1.5))
            introRunning = false
        }
    }

    private var albumIsCurrent: Bool {
        guard let playing = viewModel.currentlyPlayingItem else { return false }
        return playing.AlbumId == album.id
    }

    /// "Pop · 2014 · Lossless", like the line under the title in Apple Music.
    private func classicDetails(_ tracks: [AudioItem]) -> String {
        var parts: [String] = []
        if let genre = album.Genres?.first { parts.append(genre) }
        if let year = album.ProductionYear { parts.append(String(year)) }
        if !tracks.isEmpty, tracks.allSatisfy(\.isLossless) { parts.append("Lossless") }
        return parts.joined(separator: " · ")
    }

    private func classicFooter(_ tracks: [AudioItem]) -> String {
        let minutes = Int((tracks.compactMap(\.duration).reduce(0, +) / 60).rounded())
        let count = tracks.count == 1 ? "1 brano" : "\(tracks.count) brani"
        return minutes > 0 ? "\(count), \(minutes) minuti" : count
    }

    /// The track's own artist under its title, only when it isn't the album's.
    private func trackArtistIfDifferent(_ track: AudioItem) -> String? {
        guard let name = track.Artists?.joined(separator: ", "), !name.isEmpty,
              name != album.AlbumArtist else { return nil }
        return name
    }

    /// The "⋯" menu: repeat, download and cover, which don't fit in the row of buttons.
    private func albumMenu(_ tracks: [AudioItem]) -> some View {
        let allDownloaded = !tracks.isEmpty && tracks.allSatisfy { downloadManager.isDownloaded($0.Id) }

        return Menu {
            Button {
                showAlbumInfo = true
            } label: {
                Label("Info album", systemImage: "info.circle")
            }
            Button {
                viewModel.toggleRepeatMode()
            } label: {
                Label("Ripeti: \(viewModel.repeatMode.description)", systemImage: viewModel.repeatMode.iconName)
            }
            if allDownloaded {
                Button(role: .destructive) {
                    for track in tracks { viewModel.removeDownload(for: track.Id) }
                } label: {
                    Label("Rimuovi download", systemImage: "trash")
                }
            } else {
                Button {
                    for track in tracks where !downloadManager.isDownloaded(track.Id) {
                        viewModel.downloadTrack(track)
                    }
                } label: {
                    Label("Scarica album", systemImage: "arrow.down.circle")
                }
            }
            Button {
                showCoverPicker = true
            } label: {
                Label("Cambia copertina", systemImage: "photo")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("Altro")
    }
}

// MARK: - Track Info Sheet

private struct TrackInfoSheet: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @Environment(\.dismiss) private var dismiss
    let track: AudioItem
    let album: AlbumItem

    var body: some View {
        NavigationStack {
            List {
                // Artwork + title
                Section {
                    HStack(spacing: 14) {
                        CachedAsyncImage(
                            url: viewModel.artworkURL(for: track.AlbumId ?? track.id, size: 200)
                        ) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Rectangle().fill(Color.gray.opacity(0.2))
                                .overlay(Image(systemName: "music.note"))
                        }
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.Name)
                                .font(.headline)
                            Text(track.mainArtistName ?? "Artista sconosciuto")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let albumName = track.Album {
                                Text(albumName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // General info
                Section("Informazioni") {
                    infoRow("Durata", value: formatDuration(track.duration))
                    if let artists = track.Artists, !artists.isEmpty {
                        infoRow("Artisti", value: artists.joined(separator: ", "))
                    }
                    if let albumArtists = track.AlbumArtists, !albumArtists.isEmpty {
                        infoRow("Artisti album", value: albumArtists.map(\.Name).joined(separator: ", "))
                    }
                    if let year = album.ProductionYear {
                        infoRow("Anno", value: "\(year)")
                    }
                    if let genres = track.Genres, !genres.isEmpty {
                        infoRow("Generi", value: genres.joined(separator: ", "))
                    }
                }

                // Audio details
                if let mediaSource = track.MediaSources?.first {
                    Section("Dettagli audio") {
                        if let container = mediaSource.Container {
                            infoRow("Formato", value: container.uppercased())
                        }
                        if let bitrate = mediaSource.Bitrate, bitrate > 0 {
                            infoRow("Bitrate", value: formatBitrate(bitrate))
                        }
                        if let stream = mediaSource.MediaStreams?.first {
                            if let codec = stream.Codec {
                                infoRow("Codec", value: codec.uppercased())
                            }
                            if let sr = stream.SampleRate, sr > 0 {
                                infoRow("Frequenza", value: formatSampleRate(sr))
                            }
                            if let channels = stream.Channels {
                                infoRow("Canali", value: channelLabel(channels))
                            }
                            if let bitDepth = stream.BitDepth, bitDepth > 0 {
                                infoRow("Bit depth", value: "\(bitDepth) bit")
                            }
                            if let streamBitrate = stream.BitRate, streamBitrate > 0,
                               mediaSource.Bitrate == nil {
                                infoRow("Bitrate", value: formatBitrate(streamBitrate))
                            }
                        }
                        if track.isLossless {
                            HStack {
                                Text("Qualità")
                                Spacer()
                                Text("Lossless")
                                    .foregroundStyle(.blue)
                                    .fontWeight(.medium)
                            }
                        }
                    }
                }

                // IDs (useful for debugging / advanced users)
                Section("Identificativi") {
                    infoRow("ID brano", value: track.Id)
                    if let albumId = track.AlbumId {
                        infoRow("ID album", value: albumId)
                    }
                }
            }
            .navigationTitle("Dettagli brano")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func formatDuration(_ duration: TimeInterval?) -> String {
        guard let d = duration, !d.isNaN && !d.isInfinite && d >= 0 else { return "–" }
        let totalSeconds = Int(d)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func formatBitrate(_ bps: Int) -> String {
        let kbps = Double(bps) / 1000.0
        if kbps >= 1000 {
            return String(format: "%.1f Mbps", kbps / 1000.0)
        }
        return "\(Int(kbps)) kbps"
    }

    private func formatSampleRate(_ hz: Int) -> String {
        let kHz = Double(hz) / 1000.0
        if kHz == kHz.rounded() {
            return "\(Int(kHz)) kHz"
        }
        return String(format: "%.1f kHz", kHz)
    }

    private func channelLabel(_ channels: Int) -> String {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        default: return "\(channels) canali"
        }
    }
}
