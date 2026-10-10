// DRRankingView.swift
// "Classifica DR": the songs (or the albums) with a measured dynamic range, from the most
// dynamic down, with the analysis controls on top. The lists are built once per change
// (not in `body`), since a library can have thousands of measured songs.

import SwiftUI

// MARK: - Badge

/// "DR12" in the color of the DR database scale: red up to 7, amber 8 to 13, green from 14.
struct DRBadge: View {
    let dr: Int

    static func color(for dr: Int) -> Color {
        if dr <= 7 { return .red }
        if dr <= 13 { return Color(red: 0.93, green: 0.62, blue: 0.08) }
        return .green
    }

    var body: some View {
        let color = Self.color(for: dr)
        Text("DR\(dr)")
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .accessibilityLabel("Gamma dinamica \(dr)")
    }
}

/// "DR12" for the song playing, next to the audio format, when Settings → "DR nel player" is on and
/// the song is measured. Its own view, so a new measurement redraws only this label and not the player.
struct DRPlayerLabel: View {
    let itemId: String?
    /// Text before the DR, joined with " · " (the codec on the Mac).
    var prefix: String? = nil
    /// Starts with "· ", to follow a summary that is already on screen.
    var dotted = false

    @AppStorage(DRSettings.playerBadgeKey) private var enabled = false
    @ObservedObject private var store = DRStore.shared

    var body: some View {
        if enabled, let itemId, let result = store.results[itemId] {
            let text = [prefix, "DR\(result.dr)"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            Text(dotted ? "· \(text)" : text)
                .lineLimit(1)
                .layoutPriority(1)
                .accessibilityLabel("Gamma dinamica \(result.dr)")
        }
    }
}

// MARK: - Rows

private struct DRSongRow: Identifiable {
    let item: AudioItem
    let artist: String
    let dr: Int
    /// Lowercased "artist album title", built once so sorting doesn't compare localized strings.
    let sortKey: String
    var id: String { item.Id }
}

private struct DRAlbumRow: Identifiable {
    let album: AlbumItem
    let dr: Int
    let measured: Int
    let total: Int
    let sortKey: String
    var id: String { album.Id }
}

private enum DRRankingMode: String, CaseIterable, Identifiable {
    case songs = "Brani", albums = "Album"
    var id: String { rawValue }
}

// MARK: - Page

struct DRRankingView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var store = DRStore.shared

    @State private var mode: DRRankingMode = .songs
    /// The iPhone's search field; on the Mac the toolbar search (`globalSearchQuery`) filters.
    @State private var searchText = ""
    @State private var songs: [DRSongRow] = []
    @State private var albums: [DRAlbumRow] = []
    @State private var queue: [AudioItem] = []
    @State private var measured = 0
    @State private var didLoad = false

    private var query: String {
        #if os(macOS)
        viewModel.globalSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
    }

    /// What the lists depend on; a change rebuilds them.
    private var rebuildKey: String {
        "\(mode.rawValue)|\(query)|\(store.results.count)|\(viewModel.audioItems.count)|\(viewModel.albums.count)"
    }

    private var isEmpty: Bool { mode == .songs ? songs.isEmpty : albums.isEmpty }

    var body: some View {
        content
            .navigationTitle("Classifica DR")
            .task(id: rebuildKey) {
                // Measuring adds a song every few seconds and typing changes the query:
                // wait a moment so a burst of changes rebuilds once.
                if didLoad {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                }
                rebuild()
                didLoad = true
            }
            #if os(iOS)
            .searchable(text: $searchText, prompt: "Artista o album")
            #endif
    }

    // MARK: Build

    private func rebuild() {
        let results = store.results
        let items = viewModel.audioItems
        let q = query
        measured = items.reduce(0) { $0 + (results[$1.Id] == nil ? 0 : 1) }

        switch mode {
        case .songs:
            var rows = items.compactMap { item -> DRSongRow? in
                guard let result = results[item.Id] else { return nil }
                let artist = viewModel.artistName(for: item) ?? ""
                return DRSongRow(item: item, artist: artist, dr: result.dr,
                                 sortKey: "\(artist)\u{0}\(item.Album ?? "")\u{0}\(item.Name)".lowercased())
            }
            if !q.isEmpty {
                rows = rows.filter {
                    $0.artist.localizedCaseInsensitiveContains(q)
                        || ($0.item.Album ?? "").localizedCaseInsensitiveContains(q)
                        || $0.item.Name.localizedCaseInsensitiveContains(q)
                }
            }
            rows.sort { $0.dr != $1.dr ? $0.dr > $1.dr : $0.sortKey < $1.sortKey }
            songs = rows
            queue = rows.map(\.item)
        case .albums:
            let byAlbum = Dictionary(grouping: items, by: { $0.AlbumId ?? "" })
            var rows = viewModel.albums.compactMap { album -> DRAlbumRow? in
                guard let tracks = byAlbum[album.Id],
                      let dr = store.albumDR(trackIds: tracks.map(\.Id)) else { return nil }
                let done = tracks.reduce(0) { $0 + (results[$1.Id] == nil ? 0 : 1) }
                return DRAlbumRow(album: album, dr: dr, measured: done, total: tracks.count,
                                  sortKey: "\(album.AlbumArtist ?? "")\u{0}\(album.Name)".lowercased())
            }
            if !q.isEmpty {
                rows = rows.filter {
                    $0.album.Name.localizedCaseInsensitiveContains(q)
                        || ($0.album.AlbumArtist ?? "").localizedCaseInsensitiveContains(q)
                }
            }
            rows.sort { $0.dr != $1.dr ? $0.dr > $1.dr : $0.sortKey < $1.sortKey }
            albums = rows
        }
    }

    // MARK: Layout

    private var modePicker: some View {
        Picker("Mostra", selection: $mode) {
            ForEach(DRRankingMode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var header: some View {
        DRAnalysisHeader(items: viewModel.audioItems, measured: measured, library: viewModel.audioItems.count)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if measured == 0 {
            ContentUnavailableView("Nessun brano misurato", systemImage: "waveform.badge.magnifyingglass",
                description: Text("Tocca \"Analizza libreria\": la classifica si riempie man mano che i brani vengono misurati."))
        } else {
            ContentUnavailableView("Nessun album", systemImage: "square.stack",
                description: Text("Nessun album ha ancora un brano misurato."))
        }
    }

    #if os(iOS)
    private var content: some View {
        List {
            Section {
                header
                modePicker
            }
            .listRowSeparator(.hidden)

            if isEmpty {
                emptyState
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            } else if mode == .songs {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, row in
                    songRow(row, rank: index + 1)
                }
            } else {
                ForEach(Array(albums.enumerated()), id: \.element.id) { index, row in
                    NavigationLink {
                        AlbumTracksListView(album: row.album)
                    } label: {
                        albumRowContent(row, rank: index + 1)
                    }
                    .contextMenu { AlbumQueueMenuItems(album: row.album) }
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.bottom, 170)
        .hidesMiniPlayerOnScroll()
    }

    private func songRow(_ row: DRSongRow, rank: Int) -> some View {
        Button {
            viewModel.playerManager.play(item: row.item, in: queue)
        } label: {
            songRowContent(row, rank: rank)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .queueSwipeActions(row.item, viewModel: viewModel)
        .contextMenu {
            Button {
                viewModel.playerManager.play(item: row.item, in: queue)
            } label: { Label("Riproduci", systemImage: "play.fill") }
            QueueMenuItems(tracks: [row.item])
            Divider()
            TrackNavigationMenuItems(track: row.item)
        }
    }
    #else
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                MacPageHeader(title: "Classifica DR",
                              subtitle: measured == 0 ? nil : "\(measured.formatted()) brani misurati")
                    .padding(.bottom, 16)
                header
                modePicker
                    .frame(maxWidth: 260)
                    .padding(.vertical, 14)

                if isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 20)
                } else if mode == .songs {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, row in
                        songRow(row, rank: index + 1)
                            .background(stripe(index))
                    }
                } else {
                    ForEach(Array(albums.enumerated()), id: \.element.id) { index, row in
                        NavigationLink(value: row.album) {
                            albumRowContent(row, rank: index + 1)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(stripe(index))
                        .contextMenu { AlbumQueueMenuItems(album: row.album) }
                    }
                }
            }
            .padding(28)
        }
        .macScrollTracking()
    }

    private func stripe(_ index: Int) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(index.isMultiple(of: 2) ? Color.primary.opacity(0.035) : .clear)
    }

    private func songRow(_ row: DRSongRow, rank: Int) -> some View {
        songRowContent(row, rank: rank)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { viewModel.playerManager.play(item: row.item, in: queue) }
            .contextMenu {
                Button {
                    viewModel.playerManager.play(item: row.item, in: queue)
                } label: { Label("Riproduci", systemImage: "play.fill") }
                QueueMenuItems(tracks: [row.item])
                Divider()
                Button {
                    viewModel.toggleFavoriteTrack(row.item.id)
                } label: {
                    Label(viewModel.isTrackFavorite(row.item.id) ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti",
                          systemImage: viewModel.isTrackFavorite(row.item.id) ? "heart.slash" : "heart")
                }
            }
    }
    #endif

    // MARK: Row content

    private func songRowContent(_ row: DRSongRow, rank: Int) -> some View {
        let album = row.item.Album ?? ""
        let subtitle = [row.artist, album].filter { !$0.isEmpty }.joined(separator: " · ")
        return DRRowContent(rank: rank, coverId: row.item.AlbumId ?? row.item.id, title: row.item.Name,
                            subtitle: subtitle, dr: row.dr, note: nil)
    }

    private func albumRowContent(_ row: DRAlbumRow, rank: Int) -> some View {
        DRRowContent(rank: rank, coverId: row.album.Id, title: row.album.Name,
                     subtitle: row.album.AlbumArtist ?? "", dr: row.dr,
                     note: row.measured < row.total ? "\(row.measured)/\(row.total) misurati" : nil)
    }
}

/// One line of the ranking: rank, cover, title and subtitle, DR badge (with a note under it).
private struct DRRowContent: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let rank: Int
    let coverId: String
    let title: String
    let subtitle: String
    let dr: Int
    let note: String?

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: 34, alignment: .trailing)

            CachedAsyncImage(url: viewModel.artworkURL(for: coverId, size: 120), targetSize: 44,
                content: { $0.resizable().aspectRatio(contentMode: .fill) },
                placeholder: { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary) })
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                DRBadge(dr: dr)
                if let note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Analysis header

/// "Misurati X di Y", the start/stop button, the progress and the footnote. It observes the
/// analyzer itself, so a progress tick redraws only this block and not the lists.
private struct DRAnalysisHeader: View {
    let items: [AudioItem]
    let measured: Int
    let library: Int

    @ObservedObject private var analyzer = DRAnalyzer.shared
    @ObservedObject private var store = DRStore.shared
    @State private var pending = 0

    /// Changes when something that decides how many songs are left to measure changes.
    private var pendingKey: String {
        "\(analyzer.isRunning)|\(store.results.count)|\(items.count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Misurati \(measured) di \(library)")
                        .font(.headline)
                    if !analyzer.isRunning, pending > 0 {
                        Text("Da misurare: \(pending)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if analyzer.isRunning {
                    Button("Ferma") { analyzer.stop() }
                        .buttonStyle(.glass)
                } else {
                    Button("Analizza libreria") { analyzer.start(items: items) }
                        .buttonStyle(.glassProminent)
                        .disabled(pending == 0)
                }
            }

            if analyzer.isRunning {
                ProgressView(value: Double(analyzer.done), total: Double(max(analyzer.total, 1)))
                HStack(spacing: 6) {
                    Text("\(analyzer.done) di \(analyzer.total)")
                        .monospacedDigit()
                    if let title = analyzer.currentTitle {
                        Text("· \(title)").lineLimit(1)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if let error = analyzer.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Text(analyzer.analyzesWholeLibrary
                 ? "Il Mac scarica e misura tutti i brani della libreria. I risultati si salvano su Jellyfin e arrivano anche sugli altri dispositivi."
                 : "L'iPhone misura solo i brani scaricati o già in cache. Il Mac misura tutta la libreria e i risultati arrivano qui tramite Jellyfin.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .task(id: pendingKey) {
            pending = analyzer.pendingCount(in: items)
        }
    }
}
