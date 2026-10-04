// MacSongsTable.swift
// The song list as in Music's "Brani": a table with Title, Artist, Album and Time
// columns you can sort, a speaker on the song playing, double click to play and a
// context menu with the queue entries.

#if os(macOS)
import SwiftUI

struct MacSongsTable: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let tracks: [AudioItem]

    @State private var sortOrder: [KeyPathComparator<AudioItem>] = []
    @State private var selection = Set<String>()
    @State private var infoTrack: AudioItem?

    private var displayed: [AudioItem] {
        sortOrder.isEmpty ? tracks : tracks.sorted(using: sortOrder)
    }

    var body: some View {
        let rows = displayed
        let currentId = viewModel.currentlyPlayingItem?.id

        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Titolo", value: \.sortTitle, comparator: .localizedStandard) { track in
                HStack(spacing: 10) {
                    ZStack {
                        MacCover(itemId: track.AlbumId ?? track.id, size: 32, radius: 4, imageSize: 100)
                        if track.id == currentId {
                            Image(systemName: viewModel.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                    }
                    Text(track.Name)
                        .lineLimit(1)
                        .foregroundStyle(track.id == currentId ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    if viewModel.isTrackFavorite(track.id) {
                        Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.pink)
                    }
                }
                .padding(.vertical, 3)
                // Table cells don't get the environment from the view around the table.
                .environmentObject(viewModel)
            }
            .width(min: 220, ideal: 340)

            TableColumn("Artista", value: \.sortArtist, comparator: .localizedStandard) { track in
                Text(viewModel.artistName(for: track) ?? "").foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 120, ideal: 200)

            TableColumn("Album", value: \.sortAlbum, comparator: .localizedStandard) { track in
                Text(track.Album ?? "").foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 120, ideal: 220)

            TableColumn("Durata", value: \.sortDuration) { track in
                Text(MacFormat.clock(track.duration ?? 0)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(60)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            let picked = rows.filter { ids.contains($0.id) }
            if !picked.isEmpty {
                Button {
                    viewModel.playerManager.play(item: picked[0], in: picked.count > 1 ? picked : rows)
                } label: { Label("Riproduci", systemImage: "play.fill") }
                QueueMenuItems(tracks: picked).environmentObject(viewModel)
                Divider()
                if let first = picked.first {
                    Button {
                        picked.forEach { viewModel.toggleFavoriteTrack($0.id) }
                    } label: {
                        Label(viewModel.isTrackFavorite(first.id) ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti",
                              systemImage: viewModel.isTrackFavorite(first.id) ? "heart.slash" : "heart")
                    }
                }
                if picked.count == 1, let one = picked.first {
                    Button { infoTrack = one } label: { Label("Informazioni", systemImage: "info.circle") }
                }
            }
        } primaryAction: { ids in
            guard let first = rows.first(where: { ids.contains($0.id) }) else { return }
            viewModel.playerManager.play(item: first, in: rows)
        }
        .sheet(item: $infoTrack) { track in
            ItemInfoSheet(itemId: track.Id, kind: .track, title: track.Name)
                .environmentObject(viewModel)
        }
    }
}
#endif
