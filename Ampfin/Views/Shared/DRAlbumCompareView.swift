// DRAlbumCompareView.swift
// Album DR table in the style of dr.loudness-war.info: one row per album with DR, min DR,
// max DR and a range bar on the common 0-20 scale, sortable, filterable, with a colour legend.
// From it: the album detail (per-track DR list) and the side by side comparison of 2-6 albums
// (editions, remasters). The aggregates are computed off the main thread by
// `DRAlbumStatsStore`, never in `body`.

import SwiftUI

// MARK: - Colour scale

/// The DR colour scale shared by badges, legend and range bars: red up to DR7, orange to amber
/// for 8-13, green from 14 (same bands as the original database), blended in between.
enum DRScale {
    /// The bars and the legend end here; anything above is drawn at the edge.
    static let axisMax: Double = 20

    private static let stops: [(dr: Double, rgb: (Double, Double, Double))] = [
        (0, (0.85, 0.16, 0.14)),
        (7, (0.90, 0.30, 0.12)),
        (10, (0.93, 0.62, 0.08)),
        (13, (0.88, 0.72, 0.10)),
        (14, (0.20, 0.72, 0.32)),
    ]

    static func color(forDR dr: Double) -> Color {
        guard let first = stops.first, let last = stops.last else { return .gray }
        if dr <= first.dr { return rgbColor(first.rgb) }
        if dr >= last.dr { return rgbColor(last.rgb) }
        for index in 1..<stops.count where dr <= stops[index].dr {
            let (a, b) = (stops[index - 1], stops[index])
            let t = (dr - a.dr) / (b.dr - a.dr)
            return rgbColor((a.rgb.0 + (b.rgb.0 - a.rgb.0) * t,
                             a.rgb.1 + (b.rgb.1 - a.rgb.1) * t,
                             a.rgb.2 + (b.rgb.2 - a.rgb.2) * t))
        }
        return rgbColor(last.rgb)
    }

    private static func rgbColor(_ rgb: (Double, Double, Double)) -> Color {
        Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    /// The whole scale 0...20, for gradients drawn across a bar of that width.
    static let gradient: Gradient = Gradient(stops: (0...20).map { value in
        Gradient.Stop(color: color(forDR: Double(value)), location: Double(value) / axisMax)
    })

    /// Text on top of a scale colour: dark on the light amber/yellow band, white elsewhere.
    static func textColor(forDR dr: Int) -> Color {
        (10...13).contains(dr) ? .black.opacity(0.75) : .white
    }
}

/// The legend 00 ... 13, 14+ of the DR database.
struct DRScaleLegend: View {
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0...14, id: \.self) { value in
                Text(value == 14 ? "14+" : String(format: "%02d", value))
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(DRScale.textColor(forDR: value))
                    .frame(maxWidth: .infinity, minHeight: 20)
                    .background(DRScale.color(forDR: Double(value)), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scala DR: rosso fino a 7, ambra da 8 a 13, verde da 14")
    }
}

// MARK: - Range bar and distribution

/// Min-max of an album on the common 0-20 scale, painted with the scale's colours, with the
/// mean marked by a dot.
struct DRRangeBar: View {
    let minDR: Double
    let maxDR: Double
    let mean: Double
    var height: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            func x(_ value: Double) -> CGFloat {
                CGFloat(min(max(value, 0), DRScale.axisMax) / DRScale.axisMax) * size.width
            }
            let barHeight = height
            let barY = (size.height - barHeight) / 2
            let track = Path(roundedRect: CGRect(x: 0, y: barY, width: size.width, height: barHeight), cornerRadius: barHeight / 2)
            context.fill(track, with: .color(.secondary.opacity(0.18)))

            // At least as wide as it is tall, so a single value still shows.
            let width = min(max(x(maxDR) - x(minDR), barHeight), size.width)
            let start = min(x(minDR), size.width - width)
            let range = Path(roundedRect: CGRect(x: start, y: barY, width: width, height: barHeight), cornerRadius: barHeight / 2)
            context.fill(range, with: .linearGradient(DRScale.gradient, startPoint: .zero,
                                                      endPoint: CGPoint(x: size.width, y: 0)))

            let dot = barHeight + 4
            let dotRect = CGRect(x: x(mean) - dot / 2, y: (size.height - dot) / 2, width: dot, height: dot)
            context.fill(Path(ellipseIn: dotRect), with: .color(.white))
            context.stroke(Path(ellipseIn: dotRect), with: .color(.black.opacity(0.55)), lineWidth: 1.5)
        }
        .frame(height: height + 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gamma dinamica da \(Int(minDR)) a \(Int(maxDR)), media \(String(format: "%.1f", mean))")
    }
}

/// How the tracks of an album spread over DR 0...20: one bar per integer value.
struct DRDistribution: View {
    let values: [Int]

    var body: some View {
        Canvas { context, size in
            var counts = [Int](repeating: 0, count: 21)
            for value in values { counts[min(max(value, 0), 20)] += 1 }
            guard let top = counts.max(), top > 0 else { return }
            let slot = size.width / 21
            for (value, count) in counts.enumerated() where count > 0 {
                let barHeight = max(3, size.height * CGFloat(count) / CGFloat(top))
                let rect = CGRect(x: CGFloat(value) * slot + 1, y: size.height - barHeight,
                                  width: max(slot - 2, 2), height: barHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(DRScale.color(forDR: Double(value))))
            }
        }
        .frame(height: 40)
        .accessibilityHidden(true)
    }
}

/// 0 / 10 / 20 under a bar or distribution.
private struct DRAxisLabels: View {
    var body: some View {
        HStack {
            Text("0")
            Spacer()
            Text("10")
            Spacer()
            Text("20")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .monospacedDigit()
    }
}

// MARK: - Aggregates

/// One album with at least one measured song, with everything the table shows.
struct DRAlbumStat: Identifiable {
    let album: AlbumItem
    var id: String { album.Id }
    let artist: String
    /// 0 when the album has no year.
    let year: Int
    /// The album DR as foobar prints it: the rounded mean of the measured songs.
    let dr: Int
    let mean: Double
    let minDR: Int
    let maxDR: Int
    let measured: Int
    let total: Int
    /// "FLAC", "MP3", "FLAC/MP3" or "Misto"; empty when the server didn't say.
    let format: String
    /// "Lossless" or "Lossy", nil when unknown or mixed.
    let quality: String?
    /// The album's songs in library order (which is track order), measured or not.
    let tracks: [AudioItem]
    /// Folded (case, accents) once, so sorting and searching never fold again.
    let sortArtist: String
    let sortName: String
    let searchKey: String
    /// Artist plus title without "(Deluxe)", "Remaster" and the like: albums sharing it are editions.
    let editionKey: String

    var spread: Int { maxDR - minDR }
    var coverage: Double { total == 0 ? 0 : Double(measured) / Double(total) }
}

enum DRAlbumSortField: String, CaseIterable, Identifiable {
    case dr = "DR", minDR = "DR minimo", maxDR = "DR massimo", spread = "Ampiezza"
    case artist = "Artista", album = "Album", year = "Anno", measured = "Misurati", format = "Formato"
    var id: String { rawValue }

    func comparators(ascending: Bool) -> [KeyPathComparator<DRAlbumStat>] {
        let order: SortOrder = ascending ? .forward : .reverse
        let primary: KeyPathComparator<DRAlbumStat>
        switch self {
        case .dr: primary = KeyPathComparator(\.dr, order: order)
        case .minDR: primary = KeyPathComparator(\.minDR, order: order)
        case .maxDR: primary = KeyPathComparator(\.maxDR, order: order)
        case .spread: primary = KeyPathComparator(\.spread, order: order)
        case .artist: primary = KeyPathComparator(\.sortArtist, order: order)
        case .album: primary = KeyPathComparator(\.sortName, order: order)
        case .year: primary = KeyPathComparator(\.year, order: order)
        case .measured: primary = KeyPathComparator(\.coverage, order: order)
        case .format: primary = KeyPathComparator(\.format, order: order)
        }
        return [primary] + DRAlbumStat.tieBreakers
    }
}

extension DRAlbumStat {
    static let tieBreakers: [KeyPathComparator<DRAlbumStat>] = [
        KeyPathComparator(\.sortArtist), KeyPathComparator(\.sortName),
    ]

    /// The albums that match every word of `terms` (already folded), sorted.
    static func arrange(_ stats: [DRAlbumStat], terms: [String],
                        by order: [KeyPathComparator<DRAlbumStat>]) -> [DRAlbumStat] {
        var list = terms.isEmpty ? stats : stats.filter { stat in terms.allSatisfy { stat.searchKey.contains($0) } }
        list.sort(using: order + tieBreakers)
        return list
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func terms(_ query: String) -> [String] {
        fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

/// Every album with a measured song, rebuilt off the main thread when the results or the
/// library change. Views ask `refresh` from a debounced trigger; the same inputs build once.
@MainActor
final class DRAlbumStatsStore: ObservableObject {
    static let shared = DRAlbumStatsStore()

    @Published private(set) var stats: [DRAlbumStat] = []
    /// True only while the first build runs (the page shows a spinner instead of "no albums").
    @Published private(set) var isBuilding = false

    private var byId: [String: DRAlbumStat] = [:]
    private var editionGroups: [String: [String]] = [:]
    private var builtKey: Key?
    private var pendingKey: Key?
    private var task: Task<Void, Never>?

    /// What the aggregates depend on. The sum catches a value replaced by a new measurement
    /// or an import, which leaves the count unchanged.
    private struct Key: Equatable {
        let results: Int
        let checksum: Int
        let items: Int
        let albums: Int
    }

    func stat(id: String) -> DRAlbumStat? { byId[id] }

    /// The other albums of the same artist with the same title once "Deluxe", "Remaster"... are stripped.
    func otherEditions(of stat: DRAlbumStat) -> [DRAlbumStat] {
        (editionGroups[stat.editionKey] ?? []).compactMap { $0 == stat.id ? nil : byId[$0] }
    }

    func refresh(results: [String: DRResult], items: [AudioItem], albums: [AlbumItem]) {
        let key = Key(results: results.count,
                      checksum: results.values.reduce(0) { $0 &+ Int($1.value * 10) },
                      items: items.count, albums: albums.count)
        guard key != builtKey, key != pendingKey else { return }
        task?.cancel()
        pendingKey = key
        isBuilding = stats.isEmpty
        task = Task {
            let built = await Task.detached(priority: .userInitiated) {
                Self.build(results: results, items: items, albums: albums)
            }.value
            guard !Task.isCancelled else { return }
            byId = Dictionary(built.stats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            editionGroups = built.groups
            stats = built.stats
            builtKey = key
            pendingKey = nil
            isBuilding = false
        }
    }

    private nonisolated static func build(results: [String: DRResult], items: [AudioItem],
                                          albums: [AlbumItem]) -> (stats: [DRAlbumStat], groups: [String: [String]]) {
        var byAlbum: [String: [AudioItem]] = [:]
        for item in items {
            if let albumId = item.AlbumId { byAlbum[albumId, default: []].append(item) }
        }

        var stats: [DRAlbumStat] = []
        var groups: [String: [String]] = [:]
        for album in albums {
            guard let tracks = byAlbum[album.Id] else { continue }
            let values = tracks.compactMap { results[$0.Id]?.value }
            guard !values.isEmpty else { continue }
            let mean = values.reduce(0, +) / Double(values.count)
            let rounded = values.map { Int($0.rounded()) }

            let artist = album.AlbumArtist ?? tracks.first?.mainArtistName ?? ""
            let (format, quality) = formatSummary(of: tracks)
            let foldedArtist = DRAlbumStat.fold(artist)
            let foldedName = DRAlbumStat.fold(album.Name)
            let stat = DRAlbumStat(
                album: album, artist: artist, year: album.ProductionYear ?? 0,
                dr: Int(mean.rounded()), mean: mean,
                minDR: rounded.min() ?? 0, maxDR: rounded.max() ?? 0,
                measured: values.count, total: tracks.count,
                format: format, quality: quality, tracks: tracks,
                sortArtist: foldedArtist, sortName: foldedName,
                searchKey: "\(foldedArtist) \(foldedName)",
                editionKey: "\(foldedArtist)|\(DRTitle.base(foldedName))")
            stats.append(stat)
            groups[stat.editionKey, default: []].append(stat.id)
        }
        return (stats, groups.filter { $0.value.count > 1 })
    }

    private nonisolated static let losslessContainers: Set<String> = ["flac", "alac", "wav", "aiff", "aif", "ape", "wv", "dsf", "dff"]
    private nonisolated static let lossyContainers: Set<String> = ["mp3", "aac", "ogg", "opus", "wma", "mp2"]

    private nonisolated static func formatSummary(of tracks: [AudioItem]) -> (String, String?) {
        var seen: [String] = []
        for track in tracks {
            if let name = track.containerName, !seen.contains(name) { seen.append(name) }
        }
        let format = seen.count > 3 ? "Misto" : seen.map { $0.uppercased() }.joined(separator: "/")
        let lossless = seen.contains { losslessContainers.contains($0) }
        let lossy = seen.contains { lossyContainers.contains($0) }
        let quality: String? = lossless && lossy ? nil : (lossless ? "Lossless" : (lossy ? "Lossy" : nil))
        return (format, quality)
    }
}

/// Album titles without the edition decorations, to recognise "Album", "Album (Deluxe Edition)"
/// and "Album - 2011 Remaster" as the same record.
enum DRTitle {
    private static let keywords = "deluxe|remaster(?:ed)?|edition|expanded|anniversary|bonus|special|reissue|re-issue|collector|legacy|extended|dis[ck]\\s*\\d|cd\\s*\\d|digital|super|redux"
    private static let patterns: [NSRegularExpression] = [
        // "(Deluxe Edition)", "[2011 Remaster]"
        "\\s*[\\(\\[][^\\)\\]]*(?:\(keywords))[^\\)\\]]*[\\)\\]]",
        // " - 2011 Remaster", " - Deluxe"
        "\\s+[-\u{2013}\u{2014}]\\s+[^-\u{2013}\u{2014}]*(?:\(keywords))[^-\u{2013}\u{2014}]*$",
        // "Abbey Road Remastered 2009"
        "\\s+(?:deluxe|remastered|remaster|expanded|special)\\s*(?:edition|version)?\\s*(?:\\d{4})?$",
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// `folded` is the title already lowercased and without accents.
    nonisolated static func base(_ folded: String) -> String {
        var text = folded
        for pattern in patterns {
            text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        let cleaned = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return cleaned.isEmpty ? folded : cleaned
    }
}

// MARK: - Small shared views

private enum DRFormat {
    static func clock(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func decimal(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// "FLAC · Lossless", "2014 · FLAC"...
    static func line(for stat: DRAlbumStat, includeArtist: Bool = false) -> String {
        var parts: [String] = []
        if includeArtist, !stat.artist.isEmpty { parts.append(stat.artist) }
        if stat.year > 0 { parts.append(String(stat.year)) }
        if !stat.format.isEmpty { parts.append(stat.format) }
        return parts.joined(separator: " · ")
    }
}

/// An album cover, square.
private struct DRCover: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let albumId: String
    let size: CGFloat

    var body: some View {
        CachedAsyncImage(url: viewModel.artworkURL(for: albumId, size: Int(size * 3)), targetSize: size,
            content: { $0.resizable().aspectRatio(contentMode: .fill) },
            placeholder: { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary) })
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size > 80 ? 10 : 6, style: .continuous))
    }
}

/// One song of an album: number, title, duration and its DR.
private struct DRTrackLine: View {
    let number: Int
    let track: AudioItem
    let dr: Int?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .trailing)
                Text(track.Name)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(DRFormat.clock(track.duration))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let dr {
                    DRBadge(dr: dr)
                } else {
                    Text("\u{2014}")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 48)
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// "Misurati n/m" only when the album isn't complete.
private func measuredNote(_ stat: DRAlbumStat) -> String {
    "\(stat.measured)/\(stat.total) misurati"
}

// MARK: - Page

struct DRAlbumCompareView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var store = DRAlbumStatsStore.shared

    @State private var displayed: [DRAlbumStat] = []
    @State private var searchText = ""
    @State private var selection = Set<String>()
    @State private var showCompare = false
    @State private var compareIds: [String] = []
    @State private var openId: String?

    #if os(iOS)
    @AppStorage(DRAlbumCompareView.sortFieldKey) private var sortFieldRaw = DRAlbumSortField.dr.rawValue
    @AppStorage(DRAlbumCompareView.sortAscendingKey) private var sortAscending = false
    @State private var editMode: EditMode = .inactive
    #else
    @State private var sortOrder: [KeyPathComparator<DRAlbumStat>] = [KeyPathComparator(\.dr, order: .reverse)]
    #endif

    static let sortFieldKey = "drAlbumSortField"
    static let sortAscendingKey = "drAlbumSortAscending"
    private static let compareRange = 2...6

    private var canCompare: Bool { Self.compareRange.contains(selection.count) }

    var body: some View {
        content
            .navigationTitle("Confronta album")
            .task {
                refreshStats()
                rebuild()
            }
            // A measurement lands every few seconds: wait for the burst to end.
            .onReceive(DRStore.shared.$results.dropFirst().debounce(for: .seconds(1), scheduler: RunLoop.main)) { _ in
                refreshStats()
            }
            .onChange(of: viewModel.audioItems.count) { refreshStats() }
            .onChange(of: viewModel.albums.count) { refreshStats() }
            .onChange(of: store.stats.count) { rebuild() }
            .onChange(of: store.isBuilding) { rebuild() }
            .task(id: searchText) {
                // Typing: filter once the keystrokes pause.
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                rebuild()
            }
            .navigationDestination(isPresented: $showCompare) {
                comparison
            }
    }

    @ViewBuilder
    private var comparison: some View {
        #if os(macOS)
        DRCompareView(ids: compareIds).macPageChrome()
        #else
        DRCompareView(ids: compareIds)
        #endif
    }

    private func refreshStats() {
        store.refresh(results: DRStore.shared.results, items: viewModel.audioItems, albums: viewModel.albums)
    }

    private func rebuild() {
        #if os(iOS)
        let order = (DRAlbumSortField(rawValue: sortFieldRaw) ?? .dr).comparators(ascending: sortAscending)
        #else
        let order = sortOrder
        #endif
        displayed = DRAlbumStat.arrange(store.stats, terms: DRAlbumStat.terms(searchText), by: order)
        selection.formIntersection(Set(store.stats.map(\.id)))
    }

    private func compareSelection() {
        // In the order of the list, so the first column is the one on top.
        compareIds = displayed.filter { selection.contains($0.id) }.map(\.id)
        showCompare = true
    }

    private var subtitle: String? {
        guard !store.stats.isEmpty else { return nil }
        return displayed.count == store.stats.count
            ? "\(store.stats.count.formatted()) album misurati"
            : "\(displayed.count.formatted()) di \(store.stats.count.formatted()) album"
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.isBuilding {
            ProgressView().padding(.top, 30)
        } else if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            ContentUnavailableView("Nessun album misurato", systemImage: "square.stack",
                description: Text("Gli album compaiono qui appena un loro brano ha il DR: misura la libreria o importa un file DR dalla classifica."))
        }
    }

    // MARK: iOS

    #if os(iOS)
    private var sortField: DRAlbumSortField { DRAlbumSortField(rawValue: sortFieldRaw) ?? .dr }

    private var content: some View {
        List(selection: $selection) {
            Section {
                DRScaleLegend()
                HStack {
                    if let subtitle {
                        Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    sortMenu
                }
                if editMode.isEditing {
                    Text("Scegli da 2 a 6 album da confrontare.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowSeparator(.hidden)
            .selectionDisabled()

            if displayed.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            } else {
                ForEach(displayed) { stat in
                    row(stat)
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.bottom, 170)
        .hidesMiniPlayerOnScroll()
        .environment(\.editMode, $editMode)
        .searchable(text: $searchText, prompt: "Artista o album")
        .onChange(of: sortFieldRaw) { rebuild() }
        .onChange(of: sortAscending) { rebuild() }
        .navigationDestination(item: $openId) { DRAlbumDetailView(albumId: $0) }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if editMode.isEditing {
                    Button("Confronta (\(selection.count))") { compareSelection() }
                        .disabled(!canCompare)
                }
                Button(editMode.isEditing ? "Fine" : "Seleziona") {
                    withAnimation {
                        editMode = editMode.isEditing ? .inactive : .active
                        if !editMode.isEditing { selection = [] }
                    }
                }
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Ordina per", selection: $sortFieldRaw) {
                ForEach(DRAlbumSortField.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            Picker("Ordine", selection: $sortAscending) {
                Text("Crescente").tag(true)
                Text("Decrescente").tag(false)
            }
        } label: {
            Label("\(sortField.rawValue) \(sortAscending ? "\u{2191}" : "\u{2193}")", systemImage: "arrow.up.arrow.down")
                .font(.subheadline)
        }
    }

    // While selecting, a tap must pick the row: no button or link around the content.
    @ViewBuilder
    private func row(_ stat: DRAlbumStat) -> some View {
        if editMode.isEditing {
            DRAlbumCompactRow(stat: stat)
        } else {
            Button {
                openId = stat.id
            } label: {
                DRAlbumCompactRow(stat: stat)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                AlbumQueueMenuItems(album: stat.album)
                DRMeasureMenuItems(tracks: stat.tracks)
            }
        }
    }
    #else

    // MARK: Mac

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                MacPageHeader(title: "Confronta album", subtitle: subtitle)
                HStack(spacing: 16) {
                    TextField("Cerca artista o album", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    DRScaleLegend()
                        .frame(maxWidth: 460)
                    Spacer(minLength: 0)
                }
                Text("Seleziona da 2 a 6 album (\u{2318}-clic o \u{21E7}-clic) e usa \"Confronta\"; doppio clic apre il dettaglio.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 12)

            if displayed.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                Spacer(minLength: 0)
            } else {
                MacDRAlbumTable(rows: displayed, sortOrder: $sortOrder, selection: $selection,
                                canCompare: canCompare, onOpen: { openId = $0.id },
                                onCompare: { compareSelection() })
                    .macScrollTracking()
            }
        }
        .onChange(of: sortOrder) { rebuild() }
        .navigationDestination(item: $openId) { DRAlbumDetailView(albumId: $0).macPageChrome() }
        .toolbar {
            if canCompare {
                ToolbarItem {
                    Button("Confronta (\(selection.count))") { compareSelection() }
                }
            }
        }
    }
    #endif
}

#if os(iOS)
/// A compact row for the phone: cover, title, artist and year, the range bar with min and
/// max, and the album DR on the right.
private struct DRAlbumCompactRow: View {
    let stat: DRAlbumStat

    var body: some View {
        HStack(spacing: 12) {
            DRCover(albumId: stat.id, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(stat.album.Name).lineLimit(1)
                Text(DRFormat.line(for: stat, includeArtist: true))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(stat.minDR)")
                        .foregroundStyle(DRScale.color(forDR: Double(stat.minDR)))
                    DRRangeBar(minDR: Double(stat.minDR), maxDR: Double(stat.maxDR), mean: stat.mean, height: 6)
                    Text("\(stat.maxDR)")
                        .foregroundStyle(DRScale.color(forDR: Double(stat.maxDR)))
                }
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                DRBadge(dr: stat.dr)
                if stat.measured < stat.total {
                    Text(measuredNote(stat))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
#endif

// MARK: - Album detail

/// An album as dr.loudness-war.info shows it: DR, min, max, the range bar and the DR of
/// every song.
struct DRAlbumDetailView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var store = DRAlbumStatsStore.shared
    @ObservedObject private var drStore = DRStore.shared
    let albumId: String

    var body: some View {
        Group {
            if let stat = store.stat(id: albumId) {
                detail(stat)
            } else {
                ContentUnavailableView("Album non trovato", systemImage: "square.stack")
            }
        }
        .navigationTitle(store.stat(id: albumId)?.album.Name ?? "Album")
    }

    private func detail(_ stat: DRAlbumStat) -> some View {
        let results = drStore.results
        let editions = store.otherEditions(of: stat)
        let coverSize: CGFloat = {
            #if os(macOS)
            return 160
            #else
            return 110
            #endif
        }()

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    DRCover(albumId: stat.id, size: coverSize)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(stat.album.Name)
                            .font(.title2.weight(.bold))
                            .lineLimit(3)
                        if !stat.artist.isEmpty {
                            Text(stat.artist).font(.title3).foregroundStyle(.secondary)
                        }
                        let line = [stat.year > 0 ? String(stat.year) : nil,
                                    stat.format.isEmpty ? nil : stat.format,
                                    stat.quality].compactMap { $0 }.joined(separator: " · ")
                        if !line.isEmpty {
                            Text(line).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text(measuredNote(stat))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        DRBadge(dr: stat.dr)
                        statFigure("Min", stat.minDR)
                        statFigure("Max", stat.maxDR)
                        Text("media \(DRFormat.decimal(stat.mean))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    DRRangeBar(minDR: Double(stat.minDR), maxDR: Double(stat.maxDR), mean: stat.mean, height: 12)
                    DRAxisLabels()
                    DRScaleLegend().padding(.top, 4)
                }

                actions(stat, editions: editions)

                VStack(spacing: 0) {
                    ForEach(Array(stat.tracks.enumerated()), id: \.element.id) { index, track in
                        DRTrackLine(number: index + 1, track: track, dr: results[track.Id]?.dr) {
                            viewModel.playerManager.play(item: track, in: stat.tracks)
                        }
                        .contextMenu {
                            QueueMenuItems(tracks: [track])
                            DRMeasureMenuItems(tracks: [track])
                        }
                        if index < stat.tracks.count - 1 { Divider() }
                    }
                }

                if !editions.isEmpty {
                    editionsSection(stat, editions: editions)
                }
            }
            #if os(macOS)
            .padding(28)
            #else
            .padding(16)
            #endif
        }
        #if os(macOS)
        .macScrollTracking()
        #endif
    }

    private func statFigure(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(DRScale.color(forDR: Double(value)))
        }
    }

    private func actions(_ stat: DRAlbumStat, editions: [DRAlbumStat]) -> some View {
        HStack(spacing: 10) {
            Button {
                if let first = stat.tracks.first { viewModel.playerManager.play(item: first, in: stat.tracks) }
            } label: {
                Label("Riproduci", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)

            Button {
                viewModel.playerManager.playAlbumShuffled(tracks: stat.tracks)
            } label: {
                Label("Casuale", systemImage: "shuffle")
            }
            .buttonStyle(.bordered)

            NavigationLink {
                albumPage(stat.album)
            } label: {
                Label("Pagina album", systemImage: "square.stack")
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.regular)
    }

    @ViewBuilder
    private func albumPage(_ album: AlbumItem) -> some View {
        #if os(macOS)
        AlbumTracksListView(album: album).macPageChrome()
        #else
        AlbumTracksListView(album: album)
        #endif
    }

    private func editionsSection(_ stat: DRAlbumStat, editions: [DRAlbumStat]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Altre edizioni").font(.headline)
                Spacer()
                NavigationLink {
                    compare([stat.id] + editions.prefix(5).map(\.id))
                } label: {
                    Label("Confronta", systemImage: "rectangle.split.2x1")
                }
                .buttonStyle(.bordered)
            }
            ForEach(editions) { other in
                NavigationLink {
                    detailPage(other.id)
                } label: {
                    HStack(spacing: 10) {
                        DRCover(albumId: other.id, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(other.album.Name).lineLimit(1)
                            Text(DRFormat.line(for: other))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text("\(other.minDR)\u{2013}\(other.maxDR)")
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        DRBadge(dr: other.dr)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func compare(_ ids: [String]) -> some View {
        #if os(macOS)
        DRCompareView(ids: ids).macPageChrome()
        #else
        DRCompareView(ids: ids)
        #endif
    }

    @ViewBuilder
    private func detailPage(_ id: String) -> some View {
        #if os(macOS)
        DRAlbumDetailView(albumId: id).macPageChrome()
        #else
        DRAlbumDetailView(albumId: id)
        #endif
    }
}

// MARK: - Comparison

/// 2-6 albums side by side: range bar, DR distribution and the songs with their DR.
struct DRCompareView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var store = DRAlbumStatsStore.shared
    @ObservedObject private var drStore = DRStore.shared
    @State private var ids: [String]

    private static let cardWidth: CGFloat = 300
    private static let maxAlbums = 6

    init(ids: [String]) {
        _ids = State(initialValue: ids)
    }

    private var stats: [DRAlbumStat] { ids.compactMap { store.stat(id: $0) } }

    /// Editions of the compared albums that aren't compared yet.
    private func suggestions(for stats: [DRAlbumStat]) -> [DRAlbumStat] {
        var seen = Set(ids)
        var result: [DRAlbumStat] = []
        for stat in stats {
            for other in store.otherEditions(of: stat) where seen.insert(other.id).inserted {
                result.append(other)
            }
        }
        return result
    }

    var body: some View {
        let stats = stats
        let results = drStore.results

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                #if os(macOS)
                MacPageHeader(title: "Confronto album", subtitle: "\(stats.count) album sulla stessa scala 0\u{2013}20")
                #endif
                DRScaleLegend()
                    .frame(maxWidth: 460)

                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(stats) { stat in
                            card(stat, baseline: stats.first, results: results, canRemove: stats.count > 2)
                        }
                    }
                    .padding(.bottom, 8)
                }

                let more = suggestions(for: stats)
                if !more.isEmpty, stats.count < Self.maxAlbums {
                    suggestionsSection(more)
                }
            }
            #if os(macOS)
            .padding(28)
            #else
            .padding(16)
            #endif
        }
        #if os(macOS)
        .macScrollTracking()
        #endif
        .navigationTitle("Confronto")
    }

    private func card(_ stat: DRAlbumStat, baseline: DRAlbumStat?, results: [String: DRResult],
                      canRemove: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                DRCover(albumId: stat.id, size: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.album.Name).font(.headline).lineLimit(2)
                    if !stat.artist.isEmpty {
                        Text(stat.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(DRFormat.line(for: stat))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if canRemove {
                    Button {
                        ids.removeAll { $0 == stat.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Togli dal confronto")
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DRBadge(dr: stat.dr)
                if let baseline, baseline.id != stat.id {
                    let delta = stat.dr - baseline.dr
                    Text(delta == 0 ? "come il primo" : String(format: "%+d vs il primo", delta))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(delta > 0 ? Color.green : (delta < 0 ? Color.red : Color.secondary))
                }
                Spacer(minLength: 0)
            }
            HStack {
                Text("min \(stat.minDR)")
                Spacer()
                Text("media \(DRFormat.decimal(stat.mean))")
                Spacer()
                Text("max \(stat.maxDR)")
            }
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            DRRangeBar(minDR: Double(stat.minDR), maxDR: Double(stat.maxDR), mean: stat.mean, height: 10)

            let values = stat.tracks.compactMap { results[$0.Id]?.dr }
            DRDistribution(values: values)
            DRAxisLabels()

            if stat.measured < stat.total {
                Text(measuredNote(stat)).font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            VStack(spacing: 0) {
                ForEach(Array(stat.tracks.enumerated()), id: \.element.id) { index, track in
                    DRTrackLine(number: index + 1, track: track, dr: results[track.Id]?.dr) {
                        viewModel.playerManager.play(item: track, in: stat.tracks)
                    }
                }
            }

            NavigationLink {
                detailPage(stat.id)
            } label: {
                Label("Dettaglio album", systemImage: "list.number")
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(width: Self.cardWidth, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func suggestionsSection(_ more: [DRAlbumStat]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Altre edizioni").font(.headline)
            ForEach(more) { other in
                Button {
                    if ids.count < Self.maxAlbums { ids.append(other.id) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle").foregroundStyle(.tint)
                        DRCover(albumId: other.id, size: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(other.album.Name).lineLimit(1)
                            Text(DRFormat.line(for: other, includeArtist: true))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        DRBadge(dr: other.dr)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    @ViewBuilder
    private func detailPage(_ id: String) -> some View {
        #if os(macOS)
        DRAlbumDetailView(albumId: id).macPageChrome()
        #else
        DRAlbumDetailView(albumId: id)
        #endif
    }
}
