// MacAlbumPage.swift
// An album as Music shows it on the Mac: the cover on the left, title, artist and the
// Play / Shuffle buttons next to it, then the numbered songs in a list.

#if os(macOS)
import SwiftUI

struct MacAlbumPage: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let album: AlbumItem

    @State private var selection: String?
    @State private var infoTrack: AudioItem?
    @State private var showAlbumInfo = false
    @State private var showCoverPicker = false

    /// The model keeps one "open album" list; ignore it until it is this album's.
    private var tracks: [AudioItem] {
        let loaded = viewModel.selectedAlbumTracks
        return loaded.first?.AlbumId == album.id ? loaded : []
    }

    private var artist: ArtistItem? { viewModel.artist(named: album.AlbumArtist) }

    private var caption: String {
        let genre = album.Genres?.first
        let year = album.ProductionYear.map(String.init)
        return [genre, year].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if tracks.isEmpty {
                    if viewModel.isLoadingAlbum {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            MacTrackRow(track: track, number: index + 1, queue: tracks,
                                        detail: showsArtistColumn ? viewModel.artistName(for: track) : nil,
                                        striped: index.isMultiple(of: 2),
                                        selection: $selection,
                                        onInfo: { infoTrack = $0 })
                        }
                    }
                    Text(MacFormat.summary(tracks: tracks))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
        .navigationTitle(album.Name)
        .task(id: album.id) {
            await viewModel.fetchAlbumTracks(albumId: album.id)
        }
        .sheet(item: $infoTrack) { track in
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

    /// Compilations: the artist is shown per song only when songs differ from the album's.
    private var showsArtistColumn: Bool {
        tracks.contains { ($0.mainArtistName ?? "") != (album.AlbumArtist ?? "") && $0.mainArtistName != nil }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 28) {
            MacCover(itemId: album.id, size: 260, radius: 12, imageSize: 700)

            VStack(alignment: .leading, spacing: 6) {
                Text(album.Name)
                    .font(.system(size: 30, weight: .bold))
                    .lineLimit(3)
                if let name = album.AlbumArtist {
                    if let artist {
                        NavigationLink(value: artist) {
                            Text(name).font(.title2).foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(name).font(.title2).foregroundStyle(.tint)
                    }
                }
                if !caption.isEmpty {
                    Text(caption.uppercased())
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    MacPlayButtons(tracks: tracks)

                    Button {
                        viewModel.toggleFavoriteAlbum(album.id)
                    } label: {
                        Image(systemName: viewModel.isAlbumFavorite(album.id) ? "heart.fill" : "heart")
                            .foregroundStyle(viewModel.isAlbumFavorite(album.id) ? Color.pink : Color.primary)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Preferito")

                    Menu {
                        QueueMenuItems(tracks: tracks).environmentObject(viewModel)
                        Divider()
                        Button { showCoverPicker = true } label: { Label("Cambia copertina…", systemImage: "photo") }
                        Button { showAlbumInfo = true } label: { Label("Informazioni sull'album", systemImage: "info.circle") }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
    }
}
#endif
