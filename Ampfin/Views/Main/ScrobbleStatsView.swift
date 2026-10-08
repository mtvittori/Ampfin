// ScrobbleStatsView.swift
// Listening statistics in the style of last.fm: a hero card in the colors of the top album's
// cover (as the Home's top picks), dense stat tiles, gradient charts and ranked lists.
// The cover and its palette are loaded once per album and cached.

import SwiftUI
import Charts

// MARK: - Hero art

/// The top album's cover and its palette (bottom-edge color, as the Home's top picks).
struct ScrobbleHeroArt {
    let image: PlatformImage?
    let palette: HeroPalette
}

/// Covers already read, per album id, so opening a page again doesn't load or sample them.
@MainActor
enum ScrobbleColorCache {
    static var heroes: [String: ScrobbleHeroArt] = [:]
}

/// The cover and palette of an album; without a cover, the app tint.
@MainActor
func scrobbleHeroArt(for albumId: String?, viewModel: JellyfinViewModel) async -> ScrobbleHeroArt {
    let fallback = ScrobbleHeroArt(image: nil, palette: HeroPalette(background: .accentColor, isLight: false))
    guard let albumId else { return fallback }
    if let cached = ScrobbleColorCache.heroes[albumId] { return cached }
    guard let url = viewModel.artworkURL(for: albumId, size: 600),
          let image = await ImageLoader.shared.firstImage(from: [url]) else { return fallback }
    let art = ScrobbleHeroArt(image: image, palette: HeroPalette(image: image) ?? fallback.palette)
    ScrobbleColorCache.heroes[albumId] = art
    return art
}

/// Color for the charts and bars: the cover's color, lifted when it is too dark,
/// the app tint when the cover is grey.
private func scrobbleTint(_ palette: HeroPalette) -> Color {
    let r = palette.rgb[0], g = palette.rgb[1], b = palette.rgb[2]
    let high = max(r, g, b), low = min(r, g, b)
    let saturation = high == 0 ? 0 : (high - low) / high
    guard saturation > 0.15 else { return .accentColor }
    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
    guard luma < 0.35 else { return Color(red: r, green: g, blue: b) }
    return Color(red: r + (1 - r) * 0.35, green: g + (1 - g) * 0.35, blue: b + (1 - b) * 0.35)
}

/// The album whose cover makes the hero: the top album of the period.
private func scrobbleHeroAlbumId(_ summary: ScrobbleSummary?) -> String? {
    summary?.topAlbums.first.map { $0.imageItemId ?? $0.id }
}

/// "Nome · Artista" of the period's top album, for the hero's caption.
private func scrobbleAlbumCaption(_ summary: ScrobbleSummary?) -> String? {
    guard let album = summary?.topAlbums.first else { return nil }
    let artist = album.subtitle.map { " · \($0)" } ?? ""
    return "Album del periodo: \(album.name)\(artist)"
}

// MARK: - Home section

/// "Le tue statistiche ›": a hero for the week, three tiles and the top artists. Hidden without data.
struct ScrobbleHomeSection: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var store = ScrobbleStatsStore.shared
    @State private var week: ScrobbleSummary?
    @State private var art = ScrobbleHeroArt(image: nil, palette: HeroPalette.neutral)

    /// Changes only when the numbers do, so the summary is read once per load, not per redraw.
    /// Changes only when the numbers, the loading state or the error do, so the summary is read
    /// once per load, not per redraw.
    private var key: String {
        "\(store.todayCount)|\(store.weekCount)|\(store.isLoading)|\(store.lastError ?? "")|\(store.recent.first?.id ?? "")|\(store.streakDays)"
    }

    /// The title opens the page in every state.
    private var titleLink: some View {
        NavigationLink {
            ScrobbleStatsPage()
        } label: {
            HStack(spacing: 4) {
                Text("Le tue statistiche")
                    .font(.title2.weight(.bold))
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 8)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
    }

    /// What the section shows while there are no numbers: loading, failed, or no listens.
    @ViewBuilder
    private var statusCard: some View {
        if week != nil {
            statusBox {
                Text("Nessun ascolto negli ultimi 7 giorni")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if let error = store.lastError, !store.isLoading {
            statusBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Statistiche non disponibili")
                        .font(.headline)
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Riprova") {
                        Task { await store.load(using: viewModel, force: true) }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
        } else {
            statusBox {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Carico le statistiche…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statusBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .scrobbleCard()
            .padding(.horizontal, 20)
            .padding(.top, 6)
    }

    var body: some View {
        Group {
            if let week, week.totalScrobbles > 0 {
                let tint = scrobbleTint(art.palette)
                VStack(alignment: .leading, spacing: 0) {
                    titleLink

                    // The whole card and its tiles open the page, not only the title.
                    NavigationLink {
                        ScrobbleStatsPage()
                    } label: {
                        VStack(spacing: 10) {
                            ScrobbleHeroCard(title: "Ultimi 7 giorni", total: week.totalScrobbles,
                                             previous: week.previousTotal, previousLabel: "7 giorni prima",
                                             art: art, albumCaption: scrobbleAlbumCaption(week), compact: true)

                            // One glass container: a single sampling pass, and the tiles blend while they move.
                            GlassEffectContainer(spacing: 6) {
                                HStack(spacing: 8) {
                                    ScrobbleStatTile(symbol: "sun.max.fill", value: "\(store.todayCount)", label: "Oggi",
                                                     tint: tint, footnote: store.todayCount == 1 ? "ascolto" : "ascolti",
                                                     number: Double(store.todayCount))
                                    ScrobbleStatTile(symbol: "flame.fill", value: "\(store.streakDays)", label: "Serie",
                                                     tint: tint, footnote: "giorni di fila",
                                                     number: Double(store.streakDays), breathing: store.streakDays > 0)
                                    ScrobbleStatTile(symbol: "clock.fill", value: scrobbleDurationShort(week.listeningTime),
                                                     label: "Tempo", tint: tint, footnote: scrobbleAveragePerDay(week),
                                                     number: week.listeningTime / 60)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.pressable)
                    .padding(.horizontal, 20)

                    if !week.topArtists.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 16) {
                                ForEach(Array(week.topArtists.prefix(5).enumerated()), id: \.element.id) { index, artist in
                                    ScrobbleArtistChip(artist: artist, rank: index + 1, tint: tint)
                                        .coverFlow()
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                        }
                        .scrollClipDisabled()
                        .padding(.top, 6)
                    }
                }
                .task(id: scrobbleHeroAlbumId(week)) {
                    art = await scrobbleHeroArt(for: scrobbleHeroAlbumId(week), viewModel: viewModel)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    titleLink
                    statusCard
                }
            }
        }
        // Loads when the section appears; the store skips it when fresh, retries after a failure.
        .task {
            await store.load(using: viewModel)
        }
        .onChange(of: key, initial: true) {
            week = store.summary(for: .week)
        }
    }
}

/// Artist round in the Home strip: photo inside a ring of the tint, rank badge, name and play count.
private struct ScrobbleArtistChip: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let artist: ScrobbleCount
    let rank: Int
    let tint: Color

    var body: some View {
        MaybeLink(destination: viewModel.artist(named: artist.name).map { ArtistAlbumsView(artist: $0) }) {
            VStack(spacing: 6) {
                ScrobbleArtistAvatar(artist: artist, size: 76)
                    .padding(4)
                    .overlay(Circle().strokeBorder(LinearGradient(colors: [tint, tint.opacity(0.4)],
                                                                  startPoint: .topLeading, endPoint: .bottomTrailing),
                                                   lineWidth: 3))
                    .overlay(alignment: .topLeading) {
                        Text("\(rank)")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(tint))
                    }
                Text(artist.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(scrobbleCount(artist.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 96)
        }
    }
}

// MARK: - Profile page

/// last.fm-style profile: the hero, the stat tiles, the charts and the top lists, then the recent listens.
struct ScrobbleStatsPage: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var store = ScrobbleStatsStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var period: ScrobblePeriod = .week
    /// The library's songs by id, for playing and for the menus (made once, not per row).
    @State private var itemsById: [String: AudioItem] = [:]
    @State private var summary: ScrobbleSummary?
    @State private var art = ScrobbleHeroArt(image: nil, palette: HeroPalette.neutral)
    @State private var showAllArtists = false
    @State private var showAllAlbums = false
    @State private var showAllTracks = false
    /// The "now" row is on screen: the dot and the waveform animate only then.
    @State private var nowVisible = false

    private var key: String {
        "\(period.rawValue)|\(store.isLoading)|\(store.todayCount)|\(store.recent.count)|\(store.recent.first?.id ?? "")|\(store.streakDays)"
    }

    var body: some View {
        let tint = scrobbleTint(art.palette)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScrobblePeriodSelector(period: $period, tint: tint)

                if let summary {
                    if summary.totalScrobbles == 0 {
                        ContentUnavailableView("Nessun ascolto", systemImage: "chart.bar",
                            description: Text("Nel periodo scelto non ci sono ascolti."))
                            .padding(.top, 40)
                    } else {
                        ScrobbleHeroCard(title: scrobbleHeroTitle(summary.period),
                                         total: summary.totalScrobbles, previous: summary.previousTotal,
                                         previousLabel: scrobblePreviousLabel(summary.period),
                                         art: art, albumCaption: scrobbleAlbumCaption(summary))
                        totalsGrid(summary, tint: tint)
                        pageSection("Ascolti") {
                            // New identity per period: the bars grow again from the baseline.
                            ScrobbleDayChart(summary: summary, tint: tint)
                                .id(summary.period)
                                .scrobbleCard()
                                .scrobbleEdge()
                        }
                        pageSection("Ora del giorno") {
                            ScrobbleHourRing(byHour: summary.byHour, topHour: summary.topHour, tint: tint)
                                .id(summary.period)
                                .scrobbleCard()
                                .scrobbleEdge()
                        }

                        if !summary.topArtists.isEmpty {
                            rankedSection("Artisti più ascoltati", rows: summary.topArtists,
                                          kind: .artist, expanded: $showAllArtists, tint: tint)
                        }
                        if !summary.topAlbums.isEmpty {
                            rankedSection("Album più ascoltati", rows: summary.topAlbums,
                                          kind: .album, expanded: $showAllAlbums, tint: tint)
                        }
                        if !summary.topTracks.isEmpty {
                            rankedSection("Brani più ascoltati", rows: summary.topTracks,
                                          kind: .track, expanded: $showAllTracks, tint: tint)
                        }

                        if summary.isApproximate {
                            Text("Basate sui conteggi di Jellyfin: lo storico completo arriva dal plugin Playback Reporting")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                }

                if !store.recent.isEmpty {
                    pageSection("Ascolti recenti") { recentList(tint: tint) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
        .navigationTitle("Statistiche")
        .sensoryFeedback(.selection, trigger: period)
        .refreshable {
            await store.load(using: viewModel, force: true)
        }
        .task(id: viewModel.audioItems.count) {
            itemsById = Dictionary(viewModel.audioItems.map { ($0.Id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        .task {
            await store.load(using: viewModel)
        }
        .task(id: scrobbleHeroAlbumId(summary)) {
            art = await scrobbleHeroArt(for: scrobbleHeroAlbumId(summary), viewModel: viewModel)
        }
        .onChange(of: key, initial: true) {
            // Switching the period animates the whole page: hero, bars and lists.
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.5)) {
                summary = store.summary(for: period)
            }
        }
    }

    // MARK: Totals

    /// Three columns, two rows: the dense tiles of the page.
    private func totalsGrid(_ summary: ScrobbleSummary, tint: Color) -> some View {
        let peakHour = summary.topHour.map { String(format: "%02d:00", $0) } ?? "–"
        let peakCount = summary.topHour.map { scrobbleCount(summary.byHour[$0]) }
        let previous = summary.previousTotal.flatMap { $0 > 0 ? "vs \($0) prima" : nil }
        let pulse = summary.period.rawValue
        func tile(_ symbol: String, _ value: String, _ label: String, _ footnote: String?, _ number: Double,
                  breathing: Bool = false) -> some View {
            ScrobbleStatTile(symbol: symbol, value: value, label: label, tint: tint, footnote: footnote,
                             number: number, pulse: pulse, breathing: breathing, interactive: true)
        }
        return GlassEffectContainer(spacing: 6) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    tile("music.note", "\(summary.totalScrobbles)", "Ascolti",
                         previous ?? scrobblePlaysPerDay(summary), Double(summary.totalScrobbles))
                    tile("clock", scrobbleDurationShort(summary.listeningTime), "Tempo",
                         scrobbleAveragePerDay(summary), summary.listeningTime / 60)
                    tile("person.2", "\(summary.uniqueArtists)", "Artisti",
                         summary.topArtists.first.map { "1° \($0.name)" }, Double(summary.uniqueArtists))
                }
                HStack(spacing: 8) {
                    tile("music.note.list", "\(summary.uniqueTracks)", "Brani",
                         summary.topTracks.first.map { "1° \($0.name)" }, Double(summary.uniqueTracks))
                    tile("flame.fill", "\(store.streakDays)", "Serie", "giorni di fila",
                         Double(store.streakDays), breathing: store.streakDays > 0)
                    tile("sun.max.fill", peakHour, "Ora top", peakCount, Double(summary.topHour ?? 0))
                }
            }
        }
    }

    // MARK: Top lists

    private func rankedSection(_ title: String, rows: [ScrobbleCount], kind: ScrobbleRankKind,
                               expanded: Binding<Bool>, tint: Color) -> some View {
        pageSection(title) {
            let shown = expanded.wrappedValue ? rows : Array(rows.prefix(10))
            let maxCount = rows.first?.count ?? 1
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                    rankRow(rank: index + 1, row: row, kind: kind, maxCount: maxCount, queue: shown, tint: tint)
                        // Staggered, but capped so a long list doesn't make the last rows wait. Rows
                        // further down are off screen at first: they settle in as they scroll into view.
                        .entrance(.rise, delay: min(Double(index) * 0.035, 0.25), enabled: index < 6)
                        .scrobbleEdge()
                    if index < shown.count - 1 {
                        Divider().padding(.leading, 34)
                    }
                }
                if rows.count > 10 {
                    Button(expanded.wrappedValue ? "Mostra meno" : "Mostra tutti (\(rows.count))") {
                        withAnimation(.smooth(duration: 0.45)) { expanded.wrappedValue.toggle() }
                    }
                    .buttonStyle(.glass)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    .sensoryFeedback(.impact(weight: .light), trigger: expanded.wrappedValue)
                }
            }
            .scrobbleCard()
        }
    }

    @ViewBuilder
    private func rankRow(rank: Int, row: ScrobbleCount, kind: ScrobbleRankKind, maxCount: Int,
                         queue: [ScrobbleCount], tint: Color) -> some View {
        let content = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                rankNumber(rank)
                rankImage(row, kind: kind)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .lineLimit(1)
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                movementBadge(row)
                Text(scrobbleCount(row.count))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // The bar is the play count against the top of the list; it fades down the list
            // and fills from the left the first time it scrolls into view.
            ScrobbleRankBar(ratio: Double(row.count) / Double(max(maxCount, 1)), tint: tint,
                            endOpacity: fade(rank), delay: min(Double(rank - 1) * 0.035, 0.3))
                .padding(.leading, 34)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())

        switch kind {
        case .artist:
            MaybeLink(destination: viewModel.artist(named: row.name).map { ArtistAlbumsView(artist: $0) }) {
                content
            }
        case .album:
            MaybeLink(destination: viewModel.albums.first(where: { $0.Id == row.id }).map { AlbumTracksListView(album: $0) }) {
                content
            }
        case .track:
            Button {
                play(itemId: row.id, among: queue.map(\.id))
            } label: {
                content
            }
            .buttonStyle(.pressable)
            .contextMenu { trackMenu(row.id, among: queue.map(\.id)) }
        }
    }

    /// Opacity of the bar's end: full for the first place, down to 35% at the bottom.
    private func fade(_ rank: Int) -> Double {
        max(0.35, 1 - Double(rank - 1) * 0.06)
    }

    /// Rank 1 to 3 in gold, silver and bronze with a bigger number; the others plain.
    @ViewBuilder
    private func rankNumber(_ rank: Int) -> some View {
        let medal: Color? = rank == 1 ? Color(red: 1, green: 0.8, blue: 0.2)
            : rank == 2 ? Color(white: 0.78)
            : rank == 3 ? Color(red: 0.8, green: 0.5, blue: 0.2) : nil
        if let medal {
            ScrobbleMedal(rank: rank, color: medal)
        } else {
            Text("\(rank)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: Double(rank)))
                .frame(width: 22)
        }
    }

    /// "NUOVO" for a first appearance, "▲ 2" green or "▼ 1" red for the move, "–" when it stayed.
    @ViewBuilder
    private func movementBadge(_ row: ScrobbleCount) -> some View {
        if row.isNew {
            Text("NUOVO")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.teal, in: Capsule())
        } else if let change = row.rankChange {
            // The arrow is a symbol, so it swaps with the symbol replace effect when the move flips.
            HStack(spacing: 2) {
                Image(systemName: change > 0 ? "arrowtriangle.up.fill"
                      : change < 0 ? "arrowtriangle.down.fill" : "minus")
                    .font(.system(size: 8, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, options: .nonRepeating, value: change)
                if change != 0 {
                    Text("\(abs(change))")
                        .contentTransition(.numericText(value: Double(change)))
                }
            }
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(change > 0 ? Color.green : change < 0 ? Color.red : Color.secondary)
            .accessibilityLabel(change > 0 ? "Salito di \(change)" : change < 0 ? "Sceso di \(-change)" : "Invariato")
        }
    }

    @ViewBuilder
    private func rankImage(_ row: ScrobbleCount, kind: ScrobbleRankKind) -> some View {
        if kind == .artist {
            ScrobbleArtistAvatar(artist: row, size: 44)
        } else {
            CachedAsyncImage(url: viewModel.artworkURL(for: row.imageItemId ?? row.id, size: 120), targetSize: 44,
                content: { $0.resizable().aspectRatio(contentMode: .fill) },
                placeholder: { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary) })
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    // MARK: Recent

    private func recentList(tint: Color) -> some View {
        let recent = Array(store.recent.prefix(25))
        return VStack(spacing: 0) {
            ForEach(Array(recent.enumerated()), id: \.element.id) { index, listen in
                // Listening right now: the first listen, within the last 10 minutes.
                let isNow = index == 0 && Date().timeIntervalSince(listen.date) < 600
                Button {
                    play(itemId: listen.itemId, among: recent.map(\.itemId))
                } label: {
                    HStack(spacing: 12) {
                        CachedAsyncImage(url: viewModel.artworkURL(for: listen.albumId ?? listen.itemId, size: 120), targetSize: 44,
                            content: { $0.resizable().aspectRatio(contentMode: .fill) },
                            placeholder: { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary) })
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .shadow(color: tint.opacity(0.35), radius: 6, y: 3)
                            .overlay(alignment: .topTrailing) {
                                if isNow {
                                    ScrobblePulseDot(active: nowVisible).offset(x: 5, y: -5)
                                }
                            }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(listen.title)
                                .lineLimit(1)
                            Text(listen.artist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 4) {
                            if isNow {
                                // Bars lighting up in turn, only while the row is on screen.
                                Image(systemName: "waveform")
                                    .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating,
                                                  isActive: nowVisible && !reduceMotion)
                            }
                            Text(isNow ? "ora" : scrobbleRelative(listen.date))
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundStyle(isNow ? Color.green : Color.secondary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .contextMenu { trackMenu(listen.itemId, among: recent.map(\.itemId)) }
                .modifier(ScrobbleVisibility(enabled: isNow, visible: $nowVisible))
                .scrobbleEdge()
                if index < recent.count - 1 {
                    Divider().padding(.leading, 56)
                }
            }
        }
        .scrobbleCard()
    }

    /// Plays a track from the library, with the given ids as the queue.
    private func play(itemId: String, among ids: [String]) {
        guard let item = itemsById[itemId] else { return }
        let queue = ids.compactMap { itemsById[$0] }
        viewModel.playerManager.play(item: item, in: queue.isEmpty ? [item] : queue)
    }

    /// The long-press menu of the songs, as in the other lists. Built with each row, so it
    /// only reads the cached dictionary.
    @ViewBuilder
    private func trackMenu(_ itemId: String, among ids: [String]) -> some View {
        if let item = itemsById[itemId] {
            Button {
                play(itemId: itemId, among: ids)
            } label: {
                Label("Riproduci", systemImage: "play.fill")
            }
            QueueMenuItems(tracks: [item])
            Divider()
            TrackNavigationMenuItems(track: item)
        }
    }

    private func pageSection<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

// MARK: - Hero

/// Card as the Home's top picks: the cover on top, fading into a solid band in its bottom color,
/// with the big number, the change against the period before and the album of the period on the band.
struct ScrobbleHeroCard: View {
    let title: String
    let total: Int
    let previous: Int?
    let previousLabel: String
    let art: ScrobbleHeroArt
    let albumCaption: String?
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The number on screen: counts up to `total` on the page, follows it on the Home.
    @State private var shown: Int?
    /// 0 to 1: the light sweep crossing the card once.
    @State private var sheen = 0.0

    private var displayed: Int { shown ?? (compact || reduceMotion ? total : 0) }

    var body: some View {
        let palette = art.palette
        let height: CGFloat = compact ? 260 : 360
        ZStack(alignment: .bottom) {
            palette.background

            if let image = art.image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: height * 0.7)
                    .clipped()
                    // clipped() cuts the drawing, not the touches: a cover that isn't square
                    // overflows invisibly and swallowed the taps on the period picker above.
                    .allowsHitTesting(false)
                    // A little oversized, then the cover lags behind while the card scrolls away.
                    // Computed by the scroll view itself: no state, no redraw per frame.
                    .scaleEffect(reduceMotion ? 1 : 1.1, anchor: .bottom)
                    .scrollTransition(.interactive) { content, phase in
                        content.offset(y: reduceMotion ? 0 : min(phase.value, 0) * -22)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
            }

            LinearGradient(stops: [.init(color: palette.background.opacity(0), location: 0),
                                   .init(color: palette.background, location: 0.45)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: height * 0.6)

            bandText(palette)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !compact && !reduceMotion {
                sheenSweep(height: height)
            }
        }
        .foregroundStyle(palette.foreground)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.easeInOut(duration: 0.4), value: palette)
        .task(id: total) { await countUp() }
        .task(id: title) { await sweep() }
    }

    /// A soft band of light that crosses the card once, when the page opens or the period changes.
    private func sheenSweep(height: CGFloat) -> some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, .white.opacity(0.2), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 130, height: height * 1.6)
                .rotationEffect(.degrees(18))
                .offset(x: -190 + sheen * (geo.size.width + 300), y: -height * 0.3)
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func sweep() async {
        guard !compact, !reduceMotion else { return }
        sheen = 0
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 1.2)) { sheen = 1 }
    }

    /// Steps of an ease-out curve, each rolling the digits: reads as a count-up and costs nothing.
    private func countUp() async {
        if compact || reduceMotion {
            withAnimation(.smooth(duration: 0.4)) { shown = total }
            return
        }
        let from = shown ?? 0
        if shown == nil { try? await Task.sleep(for: .milliseconds(250)) }
        let steps = 10
        for step in 1...steps {
            guard !Task.isCancelled else { return }
            let eased = 1 - pow(1 - Double(step) / Double(steps), 3)
            withAnimation(.smooth(duration: 0.2)) { shown = from + Int((Double(total - from) * eased).rounded()) }
            try? await Task.sleep(for: .milliseconds(70))
        }
    }

    @ViewBuilder
    private func bandText(_ palette: HeroPalette) -> some View {
        let delta = scrobbleDelta(total: total, previous: previous)
        VStack(alignment: .leading, spacing: 6) {
            Text("Ascolti · \(title)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.secondary)
            Text("\(displayed)")
                .font(.system(size: compact ? 48 : 60, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(displayed)))
            if let delta {
                HStack(spacing: 4) {
                    Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .foregroundStyle(delta > 0 ? Color.green : delta < 0 ? Color.red : palette.secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : delta)
                    Text("\(delta > 0 ? "+" : "")\(delta)% rispetto ai \(previousLabel)")
                        .contentTransition(.numericText(value: Double(delta)))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(palette.foreground.opacity(0.15), in: Capsule())
                .animation(.smooth(duration: 0.4), value: delta)
            }
            if let albumCaption {
                Text(albumCaption)
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Change in percent against the period before, nil without a comparison.
private func scrobbleDelta(total: Int, previous: Int?) -> Int? {
    guard let previous, previous > 0 else { return nil }
    return Int((Double(total - previous) / Double(previous) * 100).rounded())
}

private func scrobbleHeroTitle(_ period: ScrobblePeriod) -> String {
    switch period {
    case .week: return "Ultimi 7 giorni"
    case .month: return "Ultimi 30 giorni"
    case .year: return "Ultimi 12 mesi"
    case .all: return "Da sempre"
    }
}

private func scrobblePreviousLabel(_ period: ScrobblePeriod) -> String {
    switch period {
    case .week: return "7 giorni prima"
    case .month: return "30 giorni prima"
    case .year: return "12 mesi prima"
    case .all: return ""
    }
}

// MARK: - Charts

/// Eased 0...1 for the item `index` of `count` when the whole animation is at `progress`:
/// items start one after the other and each lands softly (ease-out cubic).
private func scrobbleStagger(_ progress: Double, index: Int, count: Int, spread: Double = 0.5) -> Double {
    let delay = spread * Double(index) / Double(max(count, 1))
    let t = min(max((progress - delay) / (1 - spread), 0), 1)
    return 1 - pow(1 - t, 3)
}

/// Listens per day (or per month for all time): gradient bars that grow from zero one after
/// the other, an average line, and a drag to read a single bar.
private struct ScrobbleDayChart: View {
    let summary: ScrobbleSummary
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 to 1, animated once per appearance; the page gives the chart a new identity per period.
    @State private var progress = 0.0
    @State private var selected: Date?

    var body: some View {
        ScrobbleDayBars(summary: summary, tint: tint, progress: reduceMotion ? 1 : progress, selected: $selected)
            .onAppear {
                guard progress == 0, !reduceMotion else { return }
                withAnimation(.smooth(duration: 1.0)) { progress = 1 }
            }
            .sensoryFeedback(.selection, trigger: summary.dayEntry(near: selected)?.day)
    }
}

/// The chart itself. `progress` is animatable, so with up to 31 bars every frame re-draws them with
/// their own delay; longer series (the year) just grow together through the chart's own interpolation.
private struct ScrobbleDayBars: View, Animatable {
    let summary: ScrobbleSummary
    let tint: Color
    var progress: Double
    @Binding var selected: Date?

    private var staggered: Bool { summary.byDay.count <= 31 }

    var animatableData: Double {
        get { staggered ? progress : 0 }
        set { if staggered { progress = newValue } }
    }

    var body: some View {
        // All-time data comes per month, the other periods per day.
        let unit: Calendar.Component = summary.period == .all ? .month : .day
        let count = summary.byDay.count
        let peak = summary.byDay.map(\.count).max() ?? 0
        let average = count > 0 ? Double(summary.byDay.reduce(0) { $0 + $1.count }) / Double(count) : 0
        let picked = summary.dayEntry(near: selected)?.day
        let fill = AnyShapeStyle(LinearGradient(colors: [tint.opacity(0.3), tint.opacity(0.85)],
                                                startPoint: .bottom, endPoint: .top))
        let peakFill = AnyShapeStyle(tint)
        Chart {
            ForEach(summary.byDay.indices, id: \.self) { index in
                let entry = summary.byDay[index]
                let isPeak = entry.count == peak && peak > 0
                let isToday = summary.period != .all && Calendar.current.isDateInToday(entry.day)
                let isPicked = picked == entry.day
                let growth = staggered ? scrobbleStagger(progress, index: index, count: count) : progress
                dayBar(day: entry.day, count: entry.count, unit: unit, growth: growth,
                       label: picked != nil ? nil : (isToday ? "Oggi · \(entry.count)" : (isPeak ? "\(entry.count)" : nil)),
                       fill: isPeak || isToday || isPicked ? peakFill : fill,
                       dimmed: picked != nil && !isPicked,
                       pill: isPicked ? pillText(entry, unit: unit) : nil)
            }
            if average > 0, count > 1 {
                RuleMark(y: .value("Media", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.secondary.opacity(0.7 * progress))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("media \(average < 10 ? average.formatted(.number.precision(.fractionLength(1))) : "\(Int(average.rounded()))")")
                            .font(.caption2)
                            .foregroundStyle(.secondary.opacity(progress * progress))
                    }
            }
        }
        // A fixed scale: the bars grow, the axis doesn't rescale under them.
        .chartYScale(domain: 0...(Double(max(peak, 1)) * 1.3))
        .chartXAxis { dayAxis(for: summary.period) }
        .chartXSelection(value: $selected)
        .animation(.snappy(duration: 0.25), value: picked)
        // Every frame already carries its own growth: the chart must not also interpolate it.
        .transaction { if staggered { $0.animation = nil } }
        .frame(height: 160)
    }

    private func pillText(_ entry: (day: Date, count: Int), unit: Calendar.Component) -> String {
        let day = unit == .month ? entry.day.formatted(.dateTime.month(.abbreviated).year())
                                 : entry.day.formatted(.dateTime.day().month(.abbreviated))
        return "\(day) · \(entry.count)"
    }

    @ChartContentBuilder
    private func dayBar(day: Date, count: Int, unit: Calendar.Component, growth: Double,
                        label: String?, fill: AnyShapeStyle, dimmed: Bool, pill: String?) -> some ChartContent {
        let bar = BarMark(x: .value("Giorno", day, unit: unit), y: .value("Ascolti", Double(count) * growth))
            .foregroundStyle(fill)
            .cornerRadius(4)
            .opacity(dimmed ? 0.35 : 1)
        if let pill {
            bar.annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                Text(pill)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: Capsule())
            }
        } else if let label {
            bar.annotation(position: .top) {
                Text(label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        } else {
            bar
        }
    }

    @AxisContentBuilder
    private func dayAxis(for period: ScrobblePeriod) -> some AxisContent {
        switch period {
        case .week:
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow))
            }
        case .month:
            AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                AxisValueLabel(format: .dateTime.day())
            }
        case .year:
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.narrow))
            }
        case .all:
            AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated))
            }
        }
    }
}

private extension ScrobbleSummary {
    /// The bar (day, or month for all time) a dragged-to date falls in.
    func dayEntry(near date: Date?) -> (day: Date, count: Int)? {
        guard let date else { return nil }
        let unit: Calendar.Component = period == .all ? .month : .day
        return byDay.first { Calendar.current.isDate($0.day, equalTo: date, toGranularity: unit) }
    }
}

/// The 24 hours as a clock ring: each slice fades with its listens, the top hour in the center.
/// The slices open one after the other; dragging on the ring picks an hour and shows its listens.
private struct ScrobbleHourRing: View {
    let byHour: [Int]
    let topHour: Int?
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress = 0.0
    @State private var angle: Double?

    private var pickedHour: Int? {
        angle.map { min(max(Int($0), 0), max(byHour.count - 1, 0)) }
    }

    var body: some View {
        let shownHour = pickedHour ?? topHour
        ZStack {
            ScrobbleHourSectors(byHour: byHour, tint: tint, progress: reduceMotion ? 1 : progress,
                                picked: pickedHour, angle: $angle)
                .frame(height: 190)

            VStack(spacing: 2) {
                Text(shownHour.map { String(format: "%02d:00", $0) } ?? "–")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(shownHour ?? 0)))
                Text(pickedHour.map { scrobbleCount(byHour[$0]) } ?? "ora di punta")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(pickedHour.map { byHour[$0] } ?? 0)))
            }
            .animation(.smooth(duration: 0.25), value: pickedHour)
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            guard progress == 0, !reduceMotion else { return }
            withAnimation(.smooth(duration: 1.0)) { progress = 1 }
        }
        .sensoryFeedback(.selection, trigger: pickedHour)
    }
}

private struct ScrobbleHourSectors: View, Animatable {
    let byHour: [Int]
    let tint: Color
    var progress: Double
    let picked: Int?
    @Binding var angle: Double?

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let peak = max(byHour.max() ?? 0, 1)
        Chart(byHour.indices, id: \.self) { hour in
            let t = scrobbleStagger(progress, index: hour, count: byHour.count)
            let isPicked = picked == hour
            let strength = 0.12 + 0.88 * Double(byHour[hour]) / Double(peak)
            SectorMark(angle: .value("Ora", 1), innerRadius: .ratio(0.6),
                       outerRadius: .ratio(isPicked ? 1 : 0.55 + 0.37 * t), angularInset: 1.5)
                .cornerRadius(3)
                .foregroundStyle(tint.opacity((isPicked ? 1 : strength * (picked == nil ? 1 : 0.55)) * t))
        }
        .chartLegend(.hidden)
        .chartAngleSelection(value: $angle)
        // The picked slice grows by its own animation; the reveal frames carry theirs.
        .animation(.snappy(duration: 0.25), value: picked)
        .transaction { $0.animation = nil }
    }
}

// MARK: - Pieces

private enum ScrobbleRankKind {
    case artist, album, track
}

/// A dense stat on a tinted glass surface: icon and label on one row, the number under it,
/// and an optional small line. The number rolls its digits, the icon bounces when `pulse` changes.
private struct ScrobbleStatTile: View {
    let symbol: String
    let value: String
    let label: String
    let tint: Color
    var footnote: String? = nil
    /// The value as a number, so the digits roll up or down depending on the direction of the change.
    var number: Double = 0
    /// Anything that changes when the period does: the icon bounces.
    var pulse: String = ""
    /// A live streak: the flame breathes.
    var breathing = false
    /// Tiles of the page answer to touch like Liquid Glass; the Home's sit in a link that already does.
    var interactive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = true

    var body: some View {
        let glass: Glass = interactive ? .regular.tint(tint.opacity(0.22)).interactive()
                                       : .regular.tint(tint.opacity(0.22))
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? "" : pulse)
                    .symbolEffect(.breathe, isActive: breathing && visible && !reduceMotion)
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText(value: number))
                .animation(.smooth(duration: 0.5), value: value)
            // Always there (blank when empty), so the tiles of a row are the same height.
            Text(footnote ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassEffect(glass, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .glassEffectTransition(.materialize)
        .onScrollVisibilityChange(threshold: 0.1) { visible = $0 }
    }
}

/// "In ascolto ora": a green dot that pulses; still with Reduce Motion or when the row is off screen.
private struct ScrobblePulseDot: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.green.opacity(0.4))
                .frame(width: 14, height: 14)
                .scaleEffect(pulse ? 1.8 : 1)
                .opacity(pulse ? 0 : 1)
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
        }
        .frame(width: 16, height: 16)
        .onChange(of: active && !reduceMotion, initial: true) { _, on in
            if on {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
            } else {
                // A plain, non-repeating write replaces the endless animation.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { pulse = false }
            }
        }
        .accessibilityLabel("In ascolto ora")
    }
}

/// Glass capsule selector for the period: the highlight is one glass shape that slides
/// from option to option (glassEffectID), instead of a segmented control.
private struct ScrobblePeriodSelector: View {
    @Binding var period: ScrobblePeriod
    let tint: Color
    @Namespace private var glassSpace

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(ScrobblePeriod.allCases) { option in
                    Button {
                        guard option != period else { return }
                        withAnimation(.smooth(duration: 0.45)) { period = option }
                    } label: {
                        optionLabel(option)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(option == period ? .isSelected : [])
                }
            }
            .padding(3)
            .background(.quaternary.opacity(0.6), in: Capsule())
        }
    }

    @ViewBuilder
    private func optionLabel(_ option: ScrobblePeriod) -> some View {
        let text = Text(option.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(option == period ? Color.primary : Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .contentShape(Capsule())
        if option == period {
            // Same id on whichever option is selected: the glass travels between them.
            text
                .glassEffect(.regular.tint(tint.opacity(0.4)), in: Capsule())
                .glassEffectID("period", in: glassSpace)
        } else {
            text
        }
    }
}

/// The play-count bar of a ranked row: fills from the left with a spring the first time
/// the row scrolls into view.
private struct ScrobbleRankBar: View {
    let ratio: Double
    let tint: Color
    let endOpacity: Double
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filled = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.4), tint.opacity(endOpacity)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, geo.size.width * CGFloat(ratio)))
                    .scaleEffect(x: filled || reduceMotion ? 1 : 0.001, anchor: .leading)
            }
        }
        .frame(height: 6)
        .onScrollVisibilityChange(threshold: 0.3) { visible in
            guard visible, !filled else { return }
            withAnimation(.spring(duration: 0.7, bounce: 0.25).delay(delay)) { filled = true }
        }
    }
}

/// The number of the top three, in gold, silver or bronze: it pops in when it scrolls into view
/// and rolls when the place changes.
private struct ScrobbleMedal: View {
    let rank: Int
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        Text("\(rank)")
            .font(.system(.title3, design: .rounded, weight: .heavy))
            .monospacedDigit()
            .foregroundStyle(color)
            .contentTransition(.numericText(value: Double(rank)))
            .frame(width: 22)
            .scaleEffect(shown || reduceMotion ? 1 : 0.4)
            .onScrollVisibilityChange(threshold: 0.3) { visible in
                guard visible, !shown else { return }
                withAnimation(.spring(duration: 0.55, bounce: 0.5).delay(Double(rank) * 0.08)) { shown = true }
            }
    }
}

/// Reports whether a row is on screen, only when `enabled`.
private struct ScrobbleVisibility: ViewModifier {
    let enabled: Bool
    @Binding var visible: Bool

    func body(content: Content) -> some View {
        content.onScrollVisibilityChange(threshold: 0.2) { isVisible in
            if enabled { visible = isVisible }
        }
    }
}

/// An artist's photo in a circle, or the first letter of the name when there is none.
private struct ScrobbleArtistAvatar: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let artist: ScrobbleCount
    let size: CGFloat

    var body: some View {
        // The library's artist photo; the cover of their most played album when they aren't in it.
        let photoId = viewModel.artist(named: artist.name)?.Id ?? artist.imageItemId
        CachedAsyncImage(url: photoId.flatMap { viewModel.apiService?.imageURL(for: $0, type: "Primary", maxWidth: Int(size * 2)) },
            targetSize: size,
            content: { $0.resizable().aspectRatio(contentMode: .fill) },
            placeholder: { monogram })
            .frame(width: size, height: size)
            .clipShape(Circle())
    }

    private var monogram: some View {
        Circle()
            .fill(.quaternary)
            .overlay {
                Text(String(artist.name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
    }
}

/// Opens `destination` when there is one, else shows the label as it is.
private struct MaybeLink<Destination: View, Label: View>: View {
    let destination: Destination?
    @ViewBuilder let label: () -> Label

    var body: some View {
        if let destination {
            NavigationLink {
                destination
            } label: {
                label()
            }
            .buttonStyle(.pressable)
        } else {
            label()
        }
    }
}

private extension View {
    /// Rows and cards ease in at the screen's edges: a little smaller, dimmer and soft.
    func scrobbleEdge() -> some View {
        scrollTransition(.animated(.smooth(duration: 0.35))) { content, phase in
            content
                .opacity(phase.isIdentity ? 1 : 0.4)
                .scaleEffect(phase.isIdentity ? 1 : 0.96)
                .blur(radius: phase.isIdentity ? 0 : 2)
        }
    }

    /// Liquid Glass surface for the cards of the page.
    func scrobbleCard(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// "12 h 30 min", or "45 min" under an hour.
private func scrobbleDuration(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    let hours = minutes / 60
    if hours == 0 { return "\(minutes % 60) min" }
    return "\(hours) h \(minutes % 60) min"
}

/// "12h 30m" for the tiles, where the space is short.
private func scrobbleDurationShort(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    let hours = minutes / 60
    if hours == 0 { return "\(minutes % 60)m" }
    return "\(hours)h \(minutes % 60)m"
}

/// "≈ 45 min al giorno" over the period, nil for all time.
private func scrobbleAveragePerDay(_ summary: ScrobbleSummary) -> String? {
    let days: Double
    switch summary.period {
    case .week: days = 7
    case .month: days = 30
    case .year: days = 365
    case .all: return nil
    }
    return "≈ \(Int(summary.listeningTime / 60 / days)) min/giorno"
}

/// "≈ 21 al giorno", nil for all time.
private func scrobblePlaysPerDay(_ summary: ScrobbleSummary) -> String? {
    let days: Double
    switch summary.period {
    case .week: days = 7
    case .month: days = 30
    case .year: days = 365
    case .all: return nil
    }
    return "≈ \(Int((Double(summary.totalScrobbles) / days).rounded())) al giorno"
}

private func scrobbleAveragePerDay(_ summary: ScrobbleSummary?) -> String? {
    summary.flatMap { scrobbleAveragePerDay($0) }
}

private func scrobbleCount(_ count: Int) -> String {
    count == 1 ? "1 ascolto" : "\(count) ascolti"
}

/// "ora", "3 min fa", "2 h fa", "ieri", then the day.
private func scrobbleRelative(_ date: Date) -> String {
    let seconds = Date().timeIntervalSince(date)
    if seconds < 60 { return "ora" }
    if seconds < 3600 { return "\(Int(seconds / 60)) min fa" }
    if Calendar.current.isDateInToday(date) { return "\(Int(seconds / 3600)) h fa" }
    if Calendar.current.isDateInYesterday(date) { return "ieri" }
    return date.formatted(.dateTime.day().month(.abbreviated))
}
