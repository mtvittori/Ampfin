import SwiftUI

struct SearchResultsView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @Binding var query: String

    private enum ResultFilter: String, CaseIterable, Identifiable {
        case all = "Tutto", tracks = "Brani", albums = "Album", artists = "Artisti"
        var id: String { rawValue }
    }

    @State private var filter: ResultFilter = .all
    @ObservedObject private var colorManager = AccentColorManager.shared
    @Environment(\.zunePivotHeaderHeight) private var pivotHeader
    @FocusState private var searchFocused: Bool

    private var currentFilterHasResults: Bool {
        switch filter {
        case .all: return true
        case .tracks: return !filteredTracks.isEmpty
        case .albums: return !filteredAlbums.isEmpty
        case .artists: return !filteredArtists.isEmpty
        }
    }

    private var filteredTracks: [AudioItem] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()
        return viewModel.audioItems.filter {
            $0.Name.lowercased().contains(q) ||
            ($0.mainArtistName?.lowercased().contains(q) ?? false) ||
            ($0.Album?.lowercased().contains(q) ?? false)
        }
    }

    private var filteredAlbums: [AlbumItem] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()
        return viewModel.albums.filter {
            $0.Name.lowercased().contains(q) ||
            ($0.AlbumArtist?.lowercased().contains(q) ?? false)
        }
    }

    private var filteredArtists: [ArtistItem] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()
        return viewModel.artists.filter {
            $0.Name.lowercased().contains(q)
        }
    }

    var body: some View {
        if colorManager.zuneStyleEnabled {
            zuneBody
        } else {
            classicBody
        }
    }

    // MARK: - Zune

    private var zuneBackdropURLs: [URL] {
        if let artist = filteredArtists.first { return viewModel.artistImageURLs(for: artist) }
        if let album = filteredAlbums.first { return viewModel.artistImageURLs(for: album) }
        if let track = filteredTracks.first ?? viewModel.currentlyPlayingItem { return viewModel.artistImageURLs(for: track) }
        return []
    }

    private var zuneBody: some View {
        ZuneScreen(title: "cerca", backdropURLs: zuneBackdropURLs) {
            // No search tab in the pivot, so the page carries its own field.
            if pivotHeader > 0 {
                zuneSearchField
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
            }
            if query.isEmpty {
                ZuneNote(text: "cerca brani, album o artisti")
                    .padding(.horizontal, 20)
            } else if filteredTracks.isEmpty && filteredAlbums.isEmpty && filteredArtists.isEmpty {
                ZuneNote(text: "nessun risultato per \u{201C}\(query)\u{201D}")
                    .padding(.horizontal, 20)
            } else {
                zunePivot
                    .padding(.bottom, 4)

                let artists = Array(filteredArtists.prefix(filter == .artists ? 30 : 5))
                if (filter == .all || filter == .artists) && !artists.isEmpty {
                    ZuneSectionTitle(text: "artisti")
                        .padding(.horizontal, 20)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(artists) { artist in
                            NavigationLink(destination: ArtistAlbumsView(artist: artist)) {
                                Text(artist.Name.lowercased())
                                    .font(.zune(28, .light, relativeTo: .title2))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }

                let albums = Array(filteredAlbums.prefix(filter == .albums ? 40 : 10))
                if (filter == .all || filter == .albums) && !albums.isEmpty {
                    ZuneSectionTitle(text: "album")
                        .padding(.horizontal, 20)
                    ZuneStrip {
                        ForEach(albums) { album in
                            ZuneAlbumTile(album: album, size: 140)
                        }
                    }
                }

                let tracks = Array(filteredTracks.prefix(filter == .tracks ? 60 : 15))
                if (filter == .all || filter == .tracks) && !tracks.isEmpty {
                    ZuneSectionTitle(text: "brani")
                        .padding(.horizontal, 20)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(tracks) { track in
                            ZuneTrackRow(track: track, queue: tracks, leading: .artwork)
                        }
                    }
                    .padding(.horizontal, 20)
                }

                if !currentFilterHasResults {
                    ZuneNote(text: "nessun risultato in \u{201C}\(filter.rawValue)\u{201D}")
                        .padding(.horizontal, 20)
                }
            }
        }
    }

    private var zuneSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.7))
            TextField("", text: $query, prompt: Text("brani, album, artisti").foregroundStyle(.white.opacity(0.45)))
                .font(.zune(22, .semilight, relativeTo: .title3))
                .foregroundStyle(.white)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancella")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.14))
        .overlay(Rectangle().stroke(.white.opacity(searchFocused ? 0.9 : 0.3), lineWidth: 2))
    }

    /// Zune pivot: lowercase words in a row, the chosen one bright, the others dim.
    private var zunePivot: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(ResultFilter.allCases) { option in
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { filter = option }
                    } label: {
                        Text(option.rawValue.lowercased())
                            .font(.zune(30, .light, relativeTo: .title2))
                            .foregroundStyle(.white.opacity(filter == option ? 1 : 0.4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == option ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Classic

    private var classicBody: some View {
        Group {
            if query.isEmpty {
                ContentUnavailableView("Cerca", systemImage: "magnifyingglass", description: Text("Cerca brani, album o artisti"))
            } else if filteredTracks.isEmpty && filteredAlbums.isEmpty && filteredArtists.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                resultsList
            }
        }
        .navigationTitle("Cerca")
    }

    private var resultsList: some View {
        List {
            Section {
                Picker("Filtro risultati", selection: $filter) {
                    ForEach(ResultFilter.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            if filter == .all || filter == .artists {
                artistsSection
            }
            if filter == .all || filter == .albums {
                albumsSection
            }
            if filter == .all || filter == .tracks {
                tracksSection
            }

            if !currentFilterHasResults {
                Text("Nessun risultato in \"\(filter.rawValue)\".")
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }

            // Bottom spacer for player
            Spacer().frame(height: 90)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var artistsSection: some View {
        let artists = Array(filteredArtists.prefix(filter == .artists ? 30 : 5))
        if !artists.isEmpty {
            Section("Artisti") {
                ForEach(artists) { artist in
                    NavigationLink(destination: ArtistAlbumsView(artist: artist)) {
                        Label(artist.Name, systemImage: "music.mic")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var albumsSection: some View {
        let albums = Array(filteredAlbums.prefix(filter == .albums ? 40 : 6))
        if !albums.isEmpty {
            Section("Album") {
                ForEach(albums) { album in
                    NavigationLink(destination: AlbumTracksListView(album: album)) {
                        albumRow(album)
                    }
                }
            }
        }
    }

    private func albumRow(_ album: AlbumItem) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(
                url: viewModel.artworkURL(for: album.id, size: 100),
                content: { $0.resizable().aspectRatio(contentMode: .fill) },
                placeholder: {
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: "music.note").font(.caption))
                }
            )
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(album.Name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(album.AlbumArtist ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var tracksSection: some View {
        let tracks = Array(filteredTracks.prefix(filter == .tracks ? 60 : 15))
        if !tracks.isEmpty {
            Section("Brani") {
                ForEach(tracks) { track in
                    trackRow(track, allTracks: tracks)
                }
            }
        }
    }

    private func trackRow(_ track: AudioItem, allTracks: [AudioItem]) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(
                url: viewModel.artworkURL(for: track.AlbumId ?? track.id, size: 80),
                content: { $0.resizable().aspectRatio(contentMode: .fill) },
                placeholder: {
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: "music.note").font(.caption2))
                }
            )
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.Name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(track.mainArtistName ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if viewModel.currentlyPlayingItem?.id == track.id {
                Image(systemName: viewModel.isPlaying ? "waveform" : "pause.circle")
                    .foregroundColor(.accentColor)
                    .font(.caption)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.playerManager.play(item: track, in: allTracks)
        }
    }
}
