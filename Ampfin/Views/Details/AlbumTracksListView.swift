import SwiftUI

struct AlbumTracksListView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var downloadManager = DownloadManager.shared
    let album: AlbumItem

    @State private var selectedTrackForInfo: AudioItem?
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
            TrackInfoSheet(track: track, album: album)
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
            }
        }
        .scrollClipDisabled()
    }

    // MARK: - Classic

    private var classicBody: some View {
        List {
            albumHeader
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .padding(.bottom, 8)

            if viewModel.isLoadingAlbum {
                ProgressView()
            } else {
                ForEach(Array(viewModel.selectedAlbumTracks.enumerated()), id: \.element.id) { index, track in
                    trackRow(track: track, index: index)
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
                }
            }

            // Bottom spacer so last track isn't hidden behind the mini player
            Spacer()
                .frame(height: 90)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
    
    private var albumHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            #if os(macOS)
            // macOS: horizontal layout
            HStack(alignment: .top, spacing: 20) {
                albumArtwork
                    .frame(width: 180, height: 180)
                albumTextInfo
                Spacer()
            }
            #else
            // iOS: vertical layout (artwork centered, text below)
            VStack(spacing: 12) {
                albumArtwork
                    .frame(width: 200, height: 200)
                albumTextInfo
            }
            .frame(maxWidth: .infinity)
            #endif
            
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 12) {
                    Spacer()
                    
                    Button {
                        if let firstTrack = viewModel.selectedAlbumTracks.first {
                            viewModel.playerManager.play(item: firstTrack, in: viewModel.selectedAlbumTracks)
                        }
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.subheadline)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    
                    Button {
                        viewModel.playerManager.playAlbumShuffled(tracks: viewModel.selectedAlbumTracks)
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.subheadline)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)

                    Button {
                        viewModel.toggleFavoriteAlbum(album.id)
                    } label: {
                        Image(systemName: viewModel.isAlbumFavorite(album.id) ? "heart.fill" : "heart")
                            .font(.subheadline)
                            .foregroundColor(viewModel.isAlbumFavorite(album.id) ? .red : .primary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)

                    Button(action: { viewModel.toggleRepeatMode() }) {
                        Image(systemName: viewModel.repeatMode.iconName)
                            .font(.subheadline)
                            .foregroundColor(viewModel.repeatMode == .off ? .primary : .accentColor)
                            .frame(width: 28, height: 28)
                    }
                    .accessibilityLabel("Repeat mode")
                    #if os(macOS)
                    .help("Repeat: \(viewModel.repeatMode.description)")
                    #endif
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)

                    // Download all / remove all
                    Button {
                        let allDownloaded = viewModel.selectedAlbumTracks.allSatisfy { downloadManager.isDownloaded($0.Id) }
                        if allDownloaded {
                            for track in viewModel.selectedAlbumTracks {
                                viewModel.removeDownload(for: track.Id)
                            }
                        } else {
                            for track in viewModel.selectedAlbumTracks where !downloadManager.isDownloaded(track.Id) {
                                viewModel.downloadTrack(track)
                            }
                        }
                    } label: {
                        Image(systemName: viewModel.selectedAlbumTracks.allSatisfy({ downloadManager.isDownloaded($0.Id) }) ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .font(.subheadline)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    
                    Spacer()
                }
            }
        }.padding([.horizontal, .top])
    }

    private var albumArtwork: some View {
        AsyncImage(url: viewModel.artworkURL(for: album.id, size: 360)) { $0.resizable().aspectRatio(contentMode: .fit) }
        placeholder: { Rectangle().fill(.gray.opacity(0.3)).overlay(Image(systemName: "music.note")) }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(radius: 5)
    }

    private var albumTextInfo: some View {
        VStack(spacing: 4) {
            Text(album.Name).font(.title).fontWeight(.bold)
                .multilineTextAlignment(.center)
            Text(album.AlbumArtist ?? "Artista Sconosciuto").font(.title3).foregroundColor(.accentColor)
                .multilineTextAlignment(.center)
        }
        #if os(iOS)
        .frame(maxWidth: .infinity)
        #endif
        #if os(macOS)
        .padding(.top, 5)
        #endif
    }
    
    private func trackRow(track: AudioItem, index: Int) -> some View {
        HStack {
            Text("\(index + 1)").font(.callout).foregroundColor(.secondary).frame(minWidth: 24, alignment: .trailing)
            Text(track.Name).font(.body).lineLimit(1)
            if track.isLossless {
                Text("FLAC")
                    .font(.caption2)
                    .foregroundColor(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.blue.opacity(0.15))
                    .clipShape(Capsule())
            }
            Spacer()

            // Now-playing indicator (left of favorite)
            if viewModel.currentlyPlayingItem?.id == track.id {
                Image(systemName: viewModel.isPlaying ? "waveform" : "pause.circle")
                    .foregroundColor(.accentColor)
            }
            
            // Favorite button for track
            Button(action: {
                viewModel.toggleFavoriteTrack(track.id)
            }) {
                Image(systemName: viewModel.isTrackFavorite(track.id) ? "heart.fill" : "heart")
                    .foregroundColor(viewModel.isTrackFavorite(track.id) ? .red : .secondary)
            }
            .buttonStyle(PlainButtonStyle())

            // Download button
            downloadButton(for: track)
                .padding(.trailing, 4)

            Text(formatTime(track.duration ?? 0)).font(.callout).foregroundColor(.secondary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.playerManager.play(item: track, in: viewModel.selectedAlbumTracks)
        }
        .contextMenu {
            Button {
                viewModel.playerManager.play(item: track, in: viewModel.selectedAlbumTracks)
            } label: {
                Label("Riproduci", systemImage: "play.fill")
            }

            Button {
                viewModel.toggleFavoriteTrack(track.id)
            } label: {
                Label(
                    viewModel.isTrackFavorite(track.id) ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti",
                    systemImage: viewModel.isTrackFavorite(track.id) ? "heart.slash" : "heart"
                )
            }

            if downloadManager.isDownloaded(track.Id) {
                Button(role: .destructive) {
                    viewModel.removeDownload(for: track.Id)
                } label: {
                    Label("Rimuovi download", systemImage: "trash")
                }
            } else {
                Button {
                    viewModel.downloadTrack(track)
                } label: {
                    Label("Scarica", systemImage: "arrow.down.circle")
                }
            }

            Divider()

            Button {
                selectedTrackForInfo = track
            } label: {
                Label("Dettagli brano", systemImage: "info.circle")
            }
        }
    }
    
    @ViewBuilder
    private func downloadButton(for track: AudioItem) -> some View {
        let state = downloadManager.downloadStates[track.Id] ?? .notDownloaded
        switch state {
        case .notDownloaded:
            Button {
                viewModel.downloadTrack(track)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        case .downloading(let progress):
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 2)
                    .frame(width: 18, height: 18)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 18, height: 18)
                    .rotationEffect(.degrees(-90))
            }
            .onTapGesture {
                viewModel.removeDownload(for: track.Id)
            }
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(.accentColor)
                .contextMenu {
                    Button(role: .destructive) {
                        viewModel.removeDownload(for: track.Id)
                    } label: {
                        Label("Rimuovi download", systemImage: "trash")
                    }
                }
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard !time.isNaN && !time.isInfinite && time >= 0 else { return "0:00" }
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
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
