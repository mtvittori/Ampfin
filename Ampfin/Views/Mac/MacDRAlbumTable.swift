// MacDRAlbumTable.swift
// The album DR table for the Mac, as on dr.loudness-war.info: Artist, Album, Year, DR,
// min, max, range bar, measured and Format columns, every one sortable from its header.
// Click selects, ⌘/⇧-click picks several (to compare), double click opens the album.

#if os(macOS)
import SwiftUI

struct MacDRAlbumTable: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    /// Already filtered and sorted by the page (sorting 1,000 rows is done once per change, not per redraw).
    let rows: [DRAlbumStat]
    @Binding var sortOrder: [KeyPathComparator<DRAlbumStat>]
    @Binding var selection: Set<String>
    let canCompare: Bool
    let onOpen: (DRAlbumStat) -> Void
    let onCompare: () -> Void

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Artista", value: \.sortArtist) { stat in
                Text(stat.artist).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 110, ideal: 180)

            TableColumn("Album", value: \.sortName) { stat in
                HStack(spacing: 8) {
                    MacCover(itemId: stat.id, size: 28, radius: 4, imageSize: 100)
                    Text(stat.album.Name).lineLimit(1)
                }
                .padding(.vertical, 2)
                // Table cells don't get the environment from the view around the table.
                .environmentObject(viewModel)
            }
            .width(min: 160, ideal: 280)

            TableColumn("Anno", value: \.year) { stat in
                Text(stat.year > 0 ? String(stat.year) : "\u{2014}").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(48)

            TableColumn("DR", value: \.dr) { stat in
                DRBadge(dr: stat.dr)
            }
            .width(64)

            TableColumn("Min", value: \.minDR) { stat in
                Text("\(stat.minDR)")
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(DRScale.color(forDR: Double(stat.minDR)))
            }
            .width(40)

            TableColumn("Max", value: \.maxDR) { stat in
                Text("\(stat.maxDR)")
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(DRScale.color(forDR: Double(stat.maxDR)))
            }
            .width(40)

            TableColumn("Intervallo", value: \.spread) { stat in
                DRRangeBar(minDR: Double(stat.minDR), maxDR: Double(stat.maxDR), mean: stat.mean, height: 7)
            }
            .width(min: 90, ideal: 150)

            TableColumn("Misurati", value: \.coverage) { stat in
                Text("\(stat.measured)/\(stat.total)")
                    .monospacedDigit()
                    .foregroundStyle(stat.measured < stat.total ? .primary : .secondary)
            }
            .width(64)

            TableColumn("Formato", value: \.format) { stat in
                Text(stat.format).foregroundStyle(.secondary).lineLimit(1)
                    .help(stat.quality ?? "")
            }
            .width(min: 60, ideal: 90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            let picked = rows.filter { ids.contains($0.id) }
            if picked.count == 1, let one = picked.first {
                Button { onOpen(one) } label: { Label("Apri", systemImage: "list.number") }
                Button {
                    viewModel.playerManager.play(item: one.tracks[0], in: one.tracks)
                } label: { Label("Riproduci", systemImage: "play.fill") }
                    .disabled(one.tracks.isEmpty)
                AlbumQueueMenuItems(album: one.album).environmentObject(viewModel)
            }
            if (2...6).contains(picked.count) {
                Button { onCompare() } label: { Label("Confronta (\(picked.count))", systemImage: "rectangle.split.2x1") }
            }
            if !picked.isEmpty {
                DRMeasureMenuItems(tracks: picked.flatMap(\.tracks))
            }
        } primaryAction: { ids in
            let picked = rows.filter { ids.contains($0.id) }
            if picked.count == 1, let one = picked.first {
                onOpen(one)
            } else if canCompare {
                onCompare()
            }
        }
    }
}
#endif
