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
    /// nil while the song has no measurement (only shown in search results).
    let dr: Int?
    /// Lowercased "artist album title", built once so sorting doesn't compare localized strings.
    let sortKey: String
    /// Position in the ranking; nil in search results.
    var rank: Int?
    var id: String { item.Id }
}

private struct DRAlbumRow: Identifiable {
    let album: AlbumItem
    let tracks: [AudioItem]
    let dr: Int?
    let measured: Int
    let sortKey: String
    var rank: Int?
    /// "n/m misurati", when it is worth saying.
    let note: String?
    var id: String { album.Id }
}

private enum DRRankingMode: String, CaseIterable, Identifiable {
    case songs = "Brani", albums = "Album"
    var id: String { rawValue }
}

/// What the search looks into, folded (case and accents) once per library change so a keystroke
/// only runs `contains` over 8,000 short strings.
private final class DRSearchIndex {
    /// Parallel to `viewModel.audioItems` and `viewModel.albums`.
    private(set) var songKeys: [String] = []
    private(set) var albumKeys: [String] = []

    func prepare(items: [AudioItem], albums: [AlbumItem], artist: (AudioItem) -> String) {
        if songKeys.count != items.count {
            songKeys = items.map { Self.fold("\(artist($0)) \($0.Album ?? "") \($0.Name)") }
        }
        if albumKeys.count != albums.count {
            albumKeys = albums.map { Self.fold("\($0.AlbumArtist ?? "") \($0.Name)") }
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The words of the query; a key matches when it holds all of them.
    static func terms(_ query: String) -> [String] {
        fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func matches(_ key: String, _ terms: [String]) -> Bool {
        terms.allSatisfy { key.contains($0) }
    }
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
    @State private var searchIndex = DRSearchIndex()

    /// Song or album ids picked in selection mode (iOS) or in the list (Mac).
    @State private var selection = Set<String>()
    /// The songs behind the selection (an album is all its songs) and how many have no DR.
    @State private var selectedTracks: [AudioItem] = []
    @State private var selectedPending = 0
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #else
    @State private var openAlbum: AlbumItem?
    #endif

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
            .onChange(of: selection) { updateSelection() }
            .onChange(of: mode) { selection = [] }
            #if os(iOS)
            .searchable(text: $searchText, prompt: "Brani, album o artisti")
            #endif
    }

    // MARK: Build

    private func rebuild() {
        let results = store.results
        let items = viewModel.audioItems
        let q = query
        measured = items.reduce(0) { $0 + (results[$1.Id] == nil ? 0 : 1) }
        let terms = DRSearchIndex.terms(q)
        if !terms.isEmpty {
            searchIndex.prepare(items: items, albums: viewModel.albums) { viewModel.artistName(for: $0) ?? "" }
        }

        switch mode {
        case .songs:
            var rows: [DRSongRow] = []
            if terms.isEmpty {
                // The ranking: measured songs only.
                for item in items {
                    if let result = results[item.Id] { rows.append(songRow(item, dr: result.dr)) }
                }
            } else {
                // Search: the whole library, measured or not.
                for (index, item) in items.enumerated() where DRSearchIndex.matches(searchIndex.songKeys[index], terms) {
                    rows.append(songRow(item, dr: results[item.Id]?.dr))
                }
            }
            rows.sort { Self.precedes($0.dr, $0.sortKey, $1.dr, $1.sortKey) }
            if terms.isEmpty {
                for index in rows.indices { rows[index].rank = index + 1 }
            }
            songs = rows
            queue = rows.map(\.item)
        case .albums:
            let byAlbum = Dictionary(grouping: items, by: { $0.AlbumId ?? "" })
            var rows: [DRAlbumRow] = []
            if terms.isEmpty {
                for album in viewModel.albums {
                    guard let tracks = byAlbum[album.Id],
                          let dr = store.albumDR(trackIds: tracks.map(\.Id)) else { continue }
                    rows.append(albumRow(album, tracks: tracks, dr: dr, results: results, alwaysNote: false))
                }
            } else {
                for (index, album) in viewModel.albums.enumerated() where DRSearchIndex.matches(searchIndex.albumKeys[index], terms) {
                    let tracks = byAlbum[album.Id] ?? []
                    rows.append(albumRow(album, tracks: tracks, dr: store.albumDR(trackIds: tracks.map(\.Id)),
                                         results: results, alwaysNote: true))
                }
            }
            rows.sort { Self.precedes($0.dr, $0.sortKey, $1.dr, $1.sortKey) }
            if terms.isEmpty {
                for index in rows.indices { rows[index].rank = index + 1 }
            }
            albums = rows
        }
        updateSelection()
    }

    private func songRow(_ item: AudioItem, dr: Int?) -> DRSongRow {
        let artist = viewModel.artistName(for: item) ?? ""
        return DRSongRow(item: item, artist: artist, dr: dr,
                         sortKey: "\(artist)\u{0}\(item.Album ?? "")\u{0}\(item.Name)".lowercased())
    }

    private func albumRow(_ album: AlbumItem, tracks: [AudioItem], dr: Int?, results: [String: DRResult],
                          alwaysNote: Bool) -> DRAlbumRow {
        let done = tracks.reduce(0) { $0 + (results[$1.Id] == nil ? 0 : 1) }
        let note = !tracks.isEmpty && (alwaysNote || done < tracks.count) ? "\(done)/\(tracks.count) misurati" : nil
        return DRAlbumRow(album: album, tracks: tracks, dr: dr, measured: done,
                          sortKey: "\(album.AlbumArtist ?? "")\u{0}\(album.Name)".lowercased(), rank: nil, note: note)
    }

    /// Most dynamic first, the unmeasured last, then by name.
    private static func precedes(_ lhs: Int?, _ lhsKey: String, _ rhs: Int?, _ rhsKey: String) -> Bool {
        let (a, b) = (lhs ?? -1, rhs ?? -1)
        return a != b ? a > b : lhsKey < rhsKey
    }

    private func updateSelection() {
        var tracks: [AudioItem] = []
        if !selection.isEmpty {
            switch mode {
            case .songs: tracks = songs.filter { selection.contains($0.id) }.map(\.item)
            case .albums: tracks = albums.filter { selection.contains($0.id) }.flatMap(\.tracks)
            }
        }
        let results = store.results
        selectedTracks = tracks
        selectedPending = tracks.reduce(0) { results[$1.Id] == nil ? $0 + 1 : $0 }
    }

    /// Measures what is selected: the songs with no DR, or all of them again if every one has it.
    private func analyzeSelection() {
        DRAnalyzer.shared.enqueue(items: selectedTracks, remeasure: selectedPending == 0)
        selection = []
        #if os(iOS)
        editMode = .inactive
        #endif
    }

    private var analyzeSelectionButton: some View {
        Button(selectedPending > 0 ? "Analizza (\(selectedPending))" : "Misura di nuovo (\(selectedTracks.count))") {
            analyzeSelection()
        }
        .disabled(selectedTracks.isEmpty)
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
                description: Text("Tocca \"Analizza libreria\", oppure cerca un brano o un album e misuralo a mano. La classifica si riempie man mano che i brani vengono misurati."))
        } else {
            ContentUnavailableView("Nessun album", systemImage: "square.stack",
                description: Text("Nessun album ha ancora un brano misurato."))
        }
    }

    #if os(iOS)
    private var content: some View {
        List(selection: $selection) {
            Section {
                header
                modePicker
            }
            .listRowSeparator(.hidden)
            .selectionDisabled()

            if isEmpty {
                emptyState
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            } else if mode == .songs {
                ForEach(songs) { row in
                    songRowView(row)
                }
            } else {
                ForEach(albums) { row in
                    albumRowView(row)
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.bottom, 170)
        .hidesMiniPlayerOnScroll()
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if editMode.isEditing { analyzeSelectionButton }
                Button(editMode.isEditing ? "Fine" : "Seleziona") {
                    withAnimation {
                        editMode = editMode.isEditing ? .inactive : .active
                        if !editMode.isEditing { selection = [] }
                    }
                }
            }
        }
    }

    // While selecting, a tap must pick the row: no button or link around the content.
    @ViewBuilder
    private func songRowView(_ row: DRSongRow) -> some View {
        if editMode.isEditing {
            songRowContent(row)
        } else {
            Button {
                viewModel.playerManager.play(item: row.item, in: queue)
            } label: {
                songRowContent(row)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .queueSwipeActions(row.item, viewModel: viewModel)
            .contextMenu {
                Button {
                    viewModel.playerManager.play(item: row.item, in: queue)
                } label: { Label("Riproduci", systemImage: "play.fill") }
                QueueMenuItems(tracks: [row.item])
                DRMeasureMenuItems(tracks: [row.item])
                Divider()
                TrackNavigationMenuItems(track: row.item)
            }
        }
    }

    @ViewBuilder
    private func albumRowView(_ row: DRAlbumRow) -> some View {
        if editMode.isEditing {
            albumRowContent(row)
        } else {
            NavigationLink {
                AlbumTracksListView(album: row.album)
            } label: {
                albumRowContent(row)
            }
            .contextMenu {
                AlbumQueueMenuItems(album: row.album)
                DRMeasureMenuItems(tracks: row.tracks)
            }
        }
    }
    #else
    // A List, for the native selection: click, ⌘-click and ⇧-click pick several rows. The
    // header stays above it, since a List can't stripe its rows around header rows.
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                MacPageHeader(title: "Classifica DR",
                              subtitle: measured == 0 ? nil : "\(measured.formatted()) brani misurati")
                    .padding(.bottom, 16)
                header
                modePicker
                    .frame(maxWidth: 260)
                    .padding(.vertical, 14)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)

            if isEmpty {
                emptyState
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                Spacer(minLength: 0)
            } else {
                List(selection: $selection) {
                    if mode == .songs {
                        ForEach(songs) { songRowContent($0) }
                    } else {
                        ForEach(albums) { albumRowContent($0) }
                    }
                }
                .listStyle(.plain)
                .alternatingRowBackgrounds()
                .contextMenu(forSelectionType: String.self) { ids in
                    macMenu(ids)
                } primaryAction: { ids in
                    macOpen(ids)
                }
                .macScrollTracking()
            }
        }
        .navigationDestination(item: $openAlbum) { AlbumTracksListView(album: $0).macPageChrome() }
        .toolbar {
            if !selection.isEmpty {
                ToolbarItem { analyzeSelectionButton }
            }
        }
    }

    @ViewBuilder
    private func macMenu(_ ids: Set<String>) -> some View {
        switch mode {
        case .songs:
            let picked = songs.filter { ids.contains($0.id) }.map(\.item)
            if let first = picked.first {
                Button {
                    viewModel.playerManager.play(item: first, in: picked.count > 1 ? picked : queue)
                } label: { Label("Riproduci", systemImage: "play.fill") }
                QueueMenuItems(tracks: picked).environmentObject(viewModel)
                DRMeasureMenuItems(tracks: picked)
                Divider()
                Button {
                    picked.forEach { viewModel.toggleFavoriteTrack($0.id) }
                } label: {
                    Label(viewModel.isTrackFavorite(first.id) ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti",
                          systemImage: viewModel.isTrackFavorite(first.id) ? "heart.slash" : "heart")
                }
            }
        case .albums:
            let picked = albums.filter { ids.contains($0.id) }
            if picked.count == 1, let one = picked.first {
                AlbumQueueMenuItems(album: one.album).environmentObject(viewModel)
            }
            if !picked.isEmpty {
                DRMeasureMenuItems(tracks: picked.flatMap(\.tracks))
            }
        }
    }

    /// Double click or Return: play the song, open the album.
    private func macOpen(_ ids: Set<String>) {
        switch mode {
        case .songs:
            if let first = songs.first(where: { ids.contains($0.id) }) {
                viewModel.playerManager.play(item: first.item, in: queue)
            }
        case .albums:
            openAlbum = albums.first(where: { ids.contains($0.id) })?.album
        }
    }
    #endif

    // MARK: Row content

    private func songRowContent(_ row: DRSongRow) -> some View {
        let album = row.item.Album ?? ""
        let subtitle = [row.artist, album].filter { !$0.isEmpty }.joined(separator: " · ")
        return DRRowContent(rank: row.rank, coverId: row.item.AlbumId ?? row.item.id, title: row.item.Name,
                            subtitle: subtitle, dr: row.dr, trackIds: [row.item.Id], note: nil)
    }

    private func albumRowContent(_ row: DRAlbumRow) -> some View {
        DRRowContent(rank: row.rank, coverId: row.album.Id, title: row.album.Name,
                     subtitle: row.album.AlbumArtist ?? "", dr: row.dr, trackIds: row.tracks.map(\.Id), note: row.note)
    }
}

/// "Misura DR" for a context or "⋯" menu: the songs with no DR, and "Misura di nuovo" for the
/// ones that have it (the old value stays until the new one is ready).
struct DRMeasureMenuItems: View {
    let tracks: [AudioItem]

    var body: some View {
        let results = DRStore.shared.results
        let pending = tracks.filter { results[$0.Id] == nil }
        if !pending.isEmpty {
            Button {
                DRAnalyzer.shared.enqueue(items: pending)
            } label: {
                Label(pending.count > 1 ? "Misura DR (\(pending.count))" : "Misura DR",
                      systemImage: "waveform.badge.magnifyingglass")
            }
        }
        if pending.count < tracks.count {
            Button {
                DRAnalyzer.shared.enqueue(items: tracks, remeasure: true)
            } label: {
                Label("Misura di nuovo", systemImage: "arrow.clockwise")
            }
        }
    }
}

/// One line of the list: rank, cover, title and subtitle, DR badge (with a note under it).
private struct DRRowContent: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let rank: Int?
    let coverId: String
    let title: String
    let subtitle: String
    let dr: Int?
    /// The song, or the album's songs: a spinner shows while one of them is queued or measured.
    let trackIds: [String]
    let note: String?

    var body: some View {
        HStack(spacing: 12) {
            if let rank {
                Text("\(rank)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: 34, alignment: .trailing)
            }

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

            DRRowStatus(dr: dr, trackIds: trackIds, note: note)
        }
        .padding(.vertical, 4)
    }
}

/// The right side of a row. It observes the analyzer itself, so a song entering the queue
/// redraws this and not the list.
private struct DRRowStatus: View {
    let dr: Int?
    let trackIds: [String]
    let note: String?

    @ObservedObject private var analyzer = DRAnalyzer.shared

    var body: some View {
        let busy = trackIds.contains { analyzer.isQueuedOrMeasuring($0) }
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.small) }
                if let dr {
                    DRBadge(dr: dr)
                } else if !busy {
                    Text("—")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                        .accessibilityLabel("Non misurato")
                }
            }
            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if busy, dr == nil {
                Text("in coda")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
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
                 ? "Il Mac scarica e misura tutti i brani della libreria, oppure solo quelli scelti: selezionali e tocca Analizza. I risultati si salvano su Jellyfin e arrivano anche sugli altri dispositivi."
                 : "\"Analizza libreria\" sull'iPhone misura solo i brani scaricati o già in cache. I brani scelti a mano (Seleziona, o tieni premuto su un brano) vengono scaricati in modo temporaneo per misurarli. Il Mac misura tutta la libreria e i risultati arrivano qui tramite Jellyfin.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .task(id: pendingKey) {
            pending = analyzer.pendingCount(in: items)
        }
    }
}
