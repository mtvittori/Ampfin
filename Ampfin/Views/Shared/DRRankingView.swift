// DRRankingView.swift
// "Classifica DR": the songs (or the albums) with a measured dynamic range, from the most
// dynamic down, with the analysis controls on top. The lists are built once per change
// (not in `body`, not on the main thread: `DRRankingStore`), since a library can have
// thousands of measured songs.

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Badge

/// "DR12" in the color of the DR database scale: red up to 7, amber 8 to 13, green from 14
/// (the scale is `DRScale`, shared with the album table and its range bars).
struct DRBadge: View {
    let dr: Int

    static func color(for dr: Int) -> Color {
        DRScale.color(forDR: Double(dr))
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

extension DRBadgeStyle {
    /// Text color of a DR in the player: the DR scale, or plain white or black.
    func foreground(dr: Int) -> Color {
        switch self {
        case .colorata: DRBadge.color(for: dr)
        case .bianca: .white
        case .nera: .black
        }
    }
}

/// "DR 12 · Album DR 11" for the song playing, as plain text, when Settings → "DR nel player"
/// is on (the default). It used to be animated capsules in an overlay, which glitched the
/// player's close; now it is static text with nothing to animate, no task and no transition.
/// The values come ready from DRNowPlaying, so this looks nothing up, and the line has a fixed
/// height (unless `compact`) so the layout never moves when a song is or isn't measured.
struct DRPlayerLine: View {
    /// Shorter text ("Album 11") and no reserved height, for the Mac bar.
    var compact = false
    /// Fixed values for the settings preview: shown even when the switch is off, and nothing
    /// is read from the playing song.
    var sample: (song: Int, album: Int)?

    @AppStorage(DRSettings.playerBadgeKey) private var enabled = true
    @AppStorage(DRSettings.badgeStyleKey) private var style = DRBadgeStyle.colorata
    private let now = DRNowPlaying.shared

    static let height: CGFloat = 15

    var body: some View {
        if enabled || sample != nil {
            line
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: compact ? nil : Self.height)
        }
    }

    private var line: Text {
        // Keeps the line's height while the song is unmeasured.
        Self.text(song: sample?.song ?? now.songDR, album: sample?.album ?? now.albumDR,
                  style: style, albumLabel: compact ? "Album" : "Album DR")
            ?? Text(compact ? "" : " ")
    }

    /// "DR 12 · Album DR 11" with each number in the style's colour; nil when neither is measured.
    /// Shared with the player's info pill, which passes a shorter `albumLabel`.
    static func text(song: Int?, album: Int?, style: DRBadgeStyle, albumLabel: String) -> Text? {
        func part(_ text: String, dr: Int) -> Text {
            Text(text).foregroundStyle(style.foreground(dr: dr))
        }
        let songText = song.map { part("DR \($0)", dr: $0) }
        let albumText = album.map { part("\(albumLabel) \($0)", dr: $0) }
        switch (songText, albumText) {
        case let (song?, album?): return Text("\(song) · \(album)")
        case let (song?, nil): return song
        case let (nil, album?): return album
        case (nil, nil): return nil
        }
    }
}

// MARK: - Page

struct DRRankingView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var store = DRStore.shared

    @State private var mode: DRRankingMode = .songs
    /// The iPhone's search field; on the Mac the toolbar search (`globalSearchQuery`) filters.
    @State private var searchText = ""
    /// The rows live in a shared store that builds them off the main thread and keeps them
    /// between visits, so the page opens with the last list and refreshes behind it.
    @ObservedObject private var ranking = DRRankingStore.shared
    @State private var didLoad = false

    /// "Confronta album" page, and the DR file import with its outcome message.
    @State private var showCompare = false
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var showExporter = false
    @State private var exportFile: DRExportFile?
    @AppStorage(DRSettings.playerBadgeKey) private var playerBadge = true
    @AppStorage(DRSettings.badgeStyleKey) private var badgeStyle = DRBadgeStyle.colorata

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

    private var songs: [DRSongRow] { ranking.songs }
    private var albums: [DRAlbumRow] { ranking.albums }
    private var queue: [AudioItem] { ranking.queue }
    private var meanDR: Int? { ranking.meanDR }
    /// Until the first build the header shows the stored results, not a zero.
    private var measured: Int { ranking.hasBuilt(mode) ? ranking.measured : store.results.count }

    private var isEmpty: Bool { mode == .songs ? songs.isEmpty : albums.isEmpty }
    /// An empty list that is still being built is a spinner, not "nothing measured".
    private var isLoading: Bool { isEmpty && (ranking.isBuilding || !ranking.hasBuilt(mode)) }

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
                ranking.refresh(mode: mode, query: query, results: store.results, items: viewModel.audioItems,
                                albums: viewModel.albums, artists: viewModel.artistNameLookup,
                                libraryRevision: viewModel.libraryRevision)
                didLoad = true
            }
            .onChange(of: ranking.builds) { updateSelection() }
            .onChange(of: selection) { updateSelection() }
            .onChange(of: mode) { selection = [] }
            .navigationDestination(isPresented: $showCompare) { compareDestination }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .commaSeparatedText, .plainText]) { result in
                importDR(result)
            }
            .fileExporter(isPresented: $showExporter, document: exportFile, contentType: .json,
                          defaultFilename: DRExportFile.suggestedName) { result in
                if case .failure(let error) = result { importMessage = "Esportazione non riuscita: \(error.localizedDescription)" }
            }
            .alert("Gamma dinamica", isPresented: Binding(get: { importMessage != nil },
                                                       set: { if !$0 { importMessage = nil } })) {
                Button("OK") { importMessage = nil }
            } message: {
                Text(importMessage ?? "")
            }
            #if os(iOS)
            .searchable(text: $searchText, prompt: "Brani, album o artisti")
            #endif
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

    // MARK: Compare and import

    @ViewBuilder
    private var compareDestination: some View {
        #if os(macOS)
        DRAlbumCompareView().macPageChrome()
        #else
        DRAlbumCompareView()
        #endif
    }

    /// Reads the DR values of a file picked by the user (server script, CSV or Ampfin export).
    private func importDR(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            importMessage = error.localizedDescription
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let outcome = try store.importFile(at: url, knownIds: Set(viewModel.audioItems.map(\.Id)))
                var parts = ["\(outcome.imported) brani importati"]
                if outcome.unchanged > 0 { parts.append("\(outcome.unchanged) già uguali") }
                if outcome.skipped > 0 { parts.append("\(outcome.skipped) ignorati (non in libreria o illeggibili)") }
                importMessage = parts.joined(separator: ", ") + "."
            } catch {
                importMessage = error.localizedDescription
            }
        }
    }

    /// Same as Settings' "Esporta DR…": the file is built when the button is tapped.
    private func exportDR() {
        guard !store.results.isEmpty else {
            importMessage = "Non c'è ancora nessun DR da esportare."
            return
        }
        do {
            exportFile = DRExportFile(data: try store.exportData())
            showExporter = true
        } catch {
            importMessage = "Esportazione non riuscita: \(error.localizedDescription)"
        }
    }

    // MARK: Layout

    #if os(iOS)
    /// The page's tools in one row of equal glass buttons (icon over a short label).
    private var toolRow: some View {
        HStack(spacing: 10) {
            controlButtons
        }
    }

    /// "Nel player": the switch, the style and a preview of the label as the player shows it.
    private var playerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $playerBadge) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mostra DR")
                    Text("Nel player")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Picker("Colore", selection: $badgeStyle) {
                ForEach(DRBadgeStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                Text("Anteprima")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                // Gray backdrop so the white and black styles are both readable.
                DRPlayerLine(sample: (song: 14, album: 11))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.45), in: Capsule())
            }
        }
        .drCard()
        .opacity(playerBadge ? 1 : 0.55)
        .animation(.easeOut(duration: 0.15), value: playerBadge)
    }
    #endif

    @ViewBuilder
    private var controlButtons: some View {
        controlButton("Confronta album", short: "Confronta", systemImage: "chart.bar.xaxis") { showCompare = true }
        controlButton("Importa DR", short: "Importa", systemImage: "square.and.arrow.down") { showImporter = true }
        controlButton("Esporta DR", short: "Esporta", systemImage: "square.and.arrow.up") { exportDR() }
    }

    #if os(macOS)
    private var badgeStylePicker: some View {
        Picker("Colore", selection: $badgeStyle) {
            ForEach(DRBadgeStyle.allCases) { Text($0.title).tag($0) }
        }
        .disabled(!playerBadge)
    }
    #endif

    private func controlButton(_ title: String, short: String, systemImage: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            #if os(iOS)
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(height: 24)
                // The label keeps the plain label color: inside a Button the hierarchical `.primary`
                // resolves to the tint (the accent, unreadable on dark glass). Only the icon is tinted.
                Text(short)
                    .font(.footnote)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            #else
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
            #endif
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 16))
        .accessibilityLabel(title)
    }

    private var modePicker: some View {
        Picker("Mostra", selection: $mode) {
            ForEach(DRRankingMode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var header: some View {
        DRAnalysisHeader(items: viewModel.audioItems, measured: measured, library: viewModel.audioItems.count,
                         meanDR: meanDR)
    }

    @ViewBuilder
    private var emptyState: some View {
        if isLoading {
            ProgressView()
                .padding(.top, 24)
        } else if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if measured == 0 {
            ContentUnavailableView("Nessun brano misurato", systemImage: "waveform.badge.magnifyingglass",
                description: Text("Tocca \"Analizza\", oppure cerca un brano o un album e misuralo a mano. La classifica si riempie man mano che i brani vengono misurati."))
        } else {
            ContentUnavailableView("Nessun album", systemImage: "square.stack",
                description: Text("Nessun album ha ancora un brano misurato."))
        }
    }

    #if os(iOS)
    private var content: some View {
        List(selection: $selection) {
            // One row for the whole header, so the spacing is ours (16 between blocks).
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    toolRow
                    playerCard
                    modePicker
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
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
                    .frame(maxWidth: 560, alignment: .leading)
                HStack(alignment: .center, spacing: 10) {
                    controlButtons
                    Spacer(minLength: 8)
                    Toggle("DR nel player", isOn: $playerBadge)
                        .toggleStyle(.switch)
                    badgeStylePicker
                        .frame(maxWidth: 190)
                }
                .padding(.top, 12)
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

extension View {
    /// The rounded glass block the DR page groups its controls in.
    fileprivate func drCard() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// The summary card: how much of the library is measured, the mean DR, and the start/stop
/// button with the run's progress. It observes the analyzer itself, so a progress tick
/// redraws only this block and not the lists.
private struct DRAnalysisHeader: View {
    let items: [AudioItem]
    let measured: Int
    let library: Int
    let meanDR: Int?

    /// Thousands with a dot ("9.339"), whatever the device language.
    private static let italian = Locale(identifier: "it_IT")

    @ObservedObject private var analyzer = DRAnalyzer.shared
    @ObservedObject private var store = DRStore.shared
    @State private var pending = 0
    @State private var hasCounted = false
    @State private var showInfo = false

    /// Changes when something that decides how many songs are left to measure changes.
    private var pendingKey: String {
        "\(analyzer.isRunning)|\(store.results.count)|\(items.count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(measured.formatted(.number.locale(Self.italian)))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("di \(library.formatted(.number.locale(Self.italian))) misurati")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let meanDR {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("DR medio")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        DRBadge(dr: meanDR)
                    }
                }
            }

            ProgressView(value: Double(measured), total: Double(max(library, 1)))

            HStack(spacing: 8) {
                infoButton
                status
                Spacer(minLength: 0)
                if analyzer.isRunning {
                    Button("Ferma") { analyzer.stop() }
                        .buttonStyle(.glass)
                } else {
                    Button("Analizza") { analyzer.start(items: items) }
                        .buttonStyle(.glassProminent)
                        .disabled(pending == 0)
                }
            }
            .controlSize(.small)

            if let error = analyzer.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .drCard()
        // The count walks the whole library (on iOS with a file check per song), so it runs off
        // the main thread, and a burst of changes (a run adds a song every few seconds) counts
        // once. The task ends with the page: nothing is counted while it isn't visible.
        .task(id: pendingKey) {
            if hasCounted {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
            }
            let count = await analyzer.pendingCount(in: items)
            guard !Task.isCancelled else { return }
            pending = count
            hasCounted = true
        }
    }

    /// What the button would do, or the progress of the run: "12/340 · Title" on one line.
    @ViewBuilder
    private var status: some View {
        if analyzer.isRunning {
            Text("\(analyzer.done)/\(analyzer.total)" + (analyzer.currentTitle.map { " · \($0)" } ?? ""))
                .monospacedDigit()
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if hasCounted {
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// On the iPhone the count is only the songs it can read (downloaded or cached), which is
    /// not the whole unmeasured part of the library, so the text says so.
    private var statusText: String {
        if analyzer.analyzesWholeLibrary {
            return pending > 0 ? "\(pending.formatted()) da misurare" : "Tutto misurato"
        }
        if pending > 0 {
            return pending == 1 ? "1 brano scaricato da misurare" : "\(pending.formatted()) brani scaricati da misurare"
        }
        return measured < library ? "Nessun brano scaricato da misurare" : "Tutto misurato"
    }

    private var infoButton: some View {
        Button {
            showInfo = true
        } label: {
            Image(systemName: "info.circle")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Come funziona l'analisi")
        .popover(isPresented: $showInfo) {
            Text(analyzer.analyzesWholeLibrary
                 ? "Il Mac scarica e misura tutti i brani, oppure solo quelli selezionati. I risultati si salvano su Jellyfin e arrivano sugli altri dispositivi."
                 : "Sull'iPhone \"Analizza\" misura i brani scaricati o già in cache. Gli altri puoi sceglierli a mano (Seleziona, o tieni premuto su un brano): vengono scaricati solo per la misura. Il Mac misura tutta la libreria e i risultati arrivano qui tramite Jellyfin.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding()
                .frame(width: 300)
                .presentationCompactAdaptation(.popover)
        }
    }
}
