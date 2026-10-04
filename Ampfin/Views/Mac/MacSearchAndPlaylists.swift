// MacSearchAndPlaylists.swift
// Search results as Music shows them on the Mac (artists as round photos, albums as covers,
// songs as rows) and the playlists as a grid of covers.

#if os(macOS)
import SwiftUI

// MARK: - Search

struct MacSearchView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @Binding var query: String

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "Tutto", tracks = "Brani", albums = "Album", artists = "Artisti"
        var id: String { rawValue }
    }

    private struct Results {
        var tracks: [AudioItem] = []
        var albums: [AlbumItem] = []
        var artists: [ArtistItem] = []
    }

    @State private var filter: Filter = .all
    @State private var results = Results()
    @State private var selection: String?

    /// Worked out in the background once per search, as on the phone.
    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = Results(); return }
        try? await Task.sleep(for: .milliseconds(120))
        if Task.isCancelled { return }
        let tracks = viewModel.audioItems, albums = viewModel.albums, artists = viewModel.artists
        let found = await Task.detached(priority: .userInitiated) { () -> Results in
            func has(_ text: String?) -> Bool {
                text?.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            return Results(
                tracks: tracks.filter { has($0.Name) || has($0.mainArtistName) || has($0.Album) },
                albums: albums.filter { has($0.Name) || has($0.AlbumArtist) },
                artists: artists.filter { has($0.Name) }
            )
        }.value
        if !Task.isCancelled { results = found }
    }

    var body: some View {
        let showArtists = filter == .all || filter == .artists
        let showAlbums = filter == .all || filter == .albums
        let showTracks = filter == .all || filter == .tracks
        let artists = Array(results.artists.prefix(filter == .artists ? 60 : 12))
        let albums = Array(results.albums.prefix(filter == .albums ? 80 : 12))
        let tracks = Array(results.tracks.prefix(filter == .tracks ? 100 : 20))
        let nothing = results.artists.isEmpty && results.albums.isEmpty && results.tracks.isEmpty

        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack {
                    MacPageHeader(title: "Risultati per “\(query.trimmingCharacters(in: .whitespaces))”")
                    Picker("Filtro", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 320)
                }

                if nothing {
                    ContentUnavailableView.search(text: query)
                }

                if showArtists && !artists.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        MacSectionTitle(title: "Artisti")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 24, alignment: .top)],
                                  alignment: .leading, spacing: 22) {
                            ForEach(artists) { artist in
                                NavigationLink(value: artist) {
                                    VStack(spacing: 8) {
                                        MacArtistAvatar(artist: artist)
                                        Text(artist.Name).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if showAlbums && !albums.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        MacSectionTitle(title: "Album")
                        LazyVGrid(columns: macAlbumColumns, alignment: .leading, spacing: 26) {
                            ForEach(albums) { MacAlbumCard(album: $0) }
                        }
                    }
                }

                if showTracks && !tracks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        MacSectionTitle(title: "Brani")
                        LazyVStack(spacing: 0) {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                MacTrackRow(track: track, number: nil, queue: tracks, detail: track.Album,
                                            showsCover: true, striped: index.isMultiple(of: 2), selection: $selection)
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
        .navigationTitle("Cerca")
        .task(id: "\(query)|\(viewModel.audioItems.count)|\(viewModel.artists.count)") {
            await search()
        }
    }
}

// MARK: - Playlists

struct MacPlaylistsView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @StateObject private var playlistVM = PlaylistViewModel(apiService: nil)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                MacPageHeader(title: "Playlist",
                              subtitle: playlistVM.playlists.isEmpty ? nil : "\(playlistVM.playlists.count.formatted()) playlist")
                if playlistVM.isLoading && playlistVM.playlists.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if let error = playlistVM.errorMessage {
                    Text(error).foregroundStyle(.red)
                } else if playlistVM.playlists.isEmpty {
                    ContentUnavailableView("Nessuna playlist", systemImage: "music.note.list")
                } else {
                    LazyVGrid(columns: macAlbumColumns, alignment: .leading, spacing: 26) {
                        ForEach(playlistVM.playlists) { playlist in
                            MacPlaylistCard(playlist: playlist, playlistVM: playlistVM)
                        }
                    }
                }
            }
            .padding(28)
        }
        .navigationTitle("Playlist")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { Task { await playlistVM.fetchPlaylists() } } label: {
                    Label("Aggiorna", systemImage: "arrow.clockwise")
                }
            }
        }
        .task {
            playlistVM.setAPIService(viewModel.makePlaylistViewModel().apiService)
            await playlistVM.fetchPlaylists()
        }
    }
}

private struct MacPlaylistCard: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let playlist: PlaylistItem
    @ObservedObject var playlistVM: PlaylistViewModel
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    CachedAsyncImage(url: playlistVM.artworkURL(for: playlist.Id, size: 400), targetSize: 400) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(.quaternary)
                            .overlay(Image(systemName: "music.note.list").font(.largeTitle).foregroundStyle(.tertiary))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                .overlay(alignment: .bottomLeading) {
                    if hovering {
                        HStack(spacing: 8) {
                            Button { Task { await play(shuffled: false) } } label: {
                                Image(systemName: "play.fill").font(.system(size: 14, weight: .bold)).frame(width: 34, height: 34)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .circle)
                            Button { Task { await play(shuffled: true) } } label: {
                                Image(systemName: "shuffle").font(.system(size: 13, weight: .bold)).frame(width: 34, height: 34)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .circle)
                        }
                        .padding(8)
                        .transition(.opacity)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(playlist.Name).font(.callout.weight(.medium)).lineLimit(1)
                if let count = playlist.ItemCount {
                    Text(count == 1 ? "1 brano" : "\(count) brani").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onTapGesture(count: 2) { Task { await play(shuffled: false) } }
        .contextMenu {
            Button { Task { await play(shuffled: false) } } label: { Label("Riproduci", systemImage: "play.fill") }
            Button { Task { await play(shuffled: true) } } label: { Label("Riproduci in ordine casuale", systemImage: "shuffle") }
            Divider()
            Button { viewModel.toggleFavoritePlaylist(playlist.Id) } label: {
                Label(viewModel.isPlaylistFavorite(playlist.Id) ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti",
                      systemImage: viewModel.isPlaylistFavorite(playlist.Id) ? "heart.slash" : "heart")
            }
        }
    }

    private func play(shuffled: Bool) async {
        guard let items = try? await playlistVM.fetchPlaylistItems(playlistId: playlist.Id), let first = items.first else { return }
        if shuffled {
            viewModel.playerManager.playAlbumShuffled(tracks: items)
        } else {
            viewModel.playerManager.play(item: first, in: items)
        }
    }
}
#endif
