// MacArtistPage.swift
// An artist: round photo and name at the top with Play / Shuffle, the first songs,
// then every album as a grid of covers.

#if os(macOS)
import SwiftUI

struct MacArtistPage: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let artist: ArtistItem

    @State private var selection: String?
    @State private var showAll = false
    @State private var infoTrack: AudioItem?

    var body: some View {
        let tracks = viewModel.tracks(byArtist: artist)
        let albums = viewModel.albums(byArtist: artist)
        let shown = showAll ? tracks : Array(tracks.prefix(8))

        MacTintedPage(imageURLs: Array(viewModel.artistImageURLs(for: artist, maxWidth: 800).reversed())) { palette in
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 28) {
                    MacArtistAvatar(artist: artist, size: 180)
                        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(artist.Name)
                            .font(.system(size: 38, weight: .bold))
                            .lineLimit(2)
                        Text(details(albums: albums.count, tracks: tracks.count))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        MacPlayButtons(tracks: tracks).padding(.top, 8)
                    }
                    Spacer(minLength: 0)
                }

                if !tracks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        MacSectionTitle(title: "Brani")
                        LazyVStack(spacing: 0) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, track in
                                MacTrackRow(track: track, number: nil, queue: tracks,
                                            detail: track.Album, showsCover: true,
                                            striped: index.isMultiple(of: 2),
                                            selection: $selection, onInfo: { infoTrack = $0 })
                            }
                        }
                        .tint(palette?.foreground ?? .accentColor)
                        if tracks.count > 8 {
                            Button(showAll ? "Mostra meno" : "Mostra tutti (\(tracks.count))") { showAll.toggle() }
                                .buttonStyle(.link)
                                .padding(.horizontal, 12)
                        }
                    }
                }

                if !albums.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        MacSectionTitle(title: "Album")
                        LazyVGrid(columns: macAlbumColumns, alignment: .leading, spacing: 26) {
                            ForEach(albums) { MacAlbumCard(album: $0) }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
        .macScrollTracking()
        }
        .navigationTitle(artist.Name)
        .sheet(item: $infoTrack) { track in
            ItemInfoSheet(itemId: track.Id, kind: .track, title: track.Name)
                .environmentObject(viewModel)
        }
    }

    private func details(albums: Int, tracks: Int) -> String {
        var parts: [String] = []
        if albums > 0 { parts.append(albums == 1 ? "1 album" : "\(albums) album") }
        if tracks > 0 { parts.append(tracks == 1 ? "1 brano" : "\(tracks) brani") }
        return parts.joined(separator: " · ")
    }
}
#endif
