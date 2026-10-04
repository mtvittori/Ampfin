import SwiftUI

struct SearchResultsView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @Binding var query: String

    private enum ResultFilter: String, CaseIterable, Identifiable {
        case all = "Tutto", tracks = "Brani", albums = "Album", artists = "Artisti"
        var id: String { rawValue }
    }

    @State private var filter: ResultFilter = .all

    private var currentFilterHasResults: Bool {
        switch filter {
        case .all: return true
        case .tracks: return !filteredTracks.isEmpty
        case .albums: return !filteredAlbums.isEmpty
        case .artists: return !filteredArtists.isEmpty
        }
    }

    /// Results worked out once per search, off the main thread. They used to be
    /// recomputed (8,000+ songs, several times) at every keystroke and every redraw.
    @State private var results = Results()

    private struct Results {
        var query = ""
        var tracks: [AudioItem] = []
        var albums: [AlbumItem] = []
        var artists: [ArtistItem] = []
    }

    private var filteredTracks: [AudioItem] { query.isEmpty ? [] : results.tracks }
    private var filteredAlbums: [AlbumItem] { query.isEmpty ? [] : results.albums }
    private var filteredArtists: [ArtistItem] { query.isEmpty ? [] : results.artists }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            results = Results()
            return
        }
        // A short pause, so fast typing doesn't search for every letter.
        try? await Task.sleep(for: .milliseconds(120))
        if Task.isCancelled { return }
        let tracks = viewModel.audioItems, albums = viewModel.albums, artists = viewModel.artists
        let found = await Task.detached(priority: .userInitiated) { () -> Results in
            func has(_ text: String?) -> Bool {
                text?.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            return Results(
                query: q,
                tracks: tracks.filter { has($0.Name) || has($0.mainArtistName) || has($0.Album) },
                albums: albums.filter { has($0.Name) || has($0.AlbumArtist) },
                artists: artists.filter { has($0.Name) }
            )
        }.value
        if !Task.isCancelled { results = found }
    }

    var body: some View {
        content
        .task(id: "\(query)|\(viewModel.audioItems.count)|\(viewModel.artists.count)") {
            await search()
        }
    }

    private var content: some View {
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
            Spacer().frame(height: 150)
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
                Text(viewModel.artistName(for: track) ?? "")
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
        .queueSwipeActions(track, viewModel: viewModel)
        .contextMenu {
            QueueMenuItems(tracks: [track])
        }
    }
}
