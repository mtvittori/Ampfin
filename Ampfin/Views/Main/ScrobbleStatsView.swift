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

                            HStack(spacing: 8) {
                                ScrobbleStatTile(symbol: "sun.max.fill", value: "\(store.todayCount)", label: "Oggi",
                                                 tint: tint, footnote: store.todayCount == 1 ? "ascolto" : "ascolti")
                                ScrobbleStatTile(symbol: "flame.fill", value: "\(store.streakDays)", label: "Serie",
                                                 tint: tint, footnote: "giorni di fila")
                                ScrobbleStatTile(symbol: "clock.fill", value: scrobbleDurationShort(week.listeningTime),
                                                 label: "Tempo", tint: tint, footnote: scrobbleAveragePerDay(week))
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

    private var key: String {
        "\(period.rawValue)|\(store.isLoading)|\(store.todayCount)|\(store.recent.count)|\(store.recent.first?.id ?? "")|\(store.streakDays)"
    }

    var body: some View {
        let tint = scrobbleTint(art.palette)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Periodo", selection: $period) {
                    ForEach(ScrobblePeriod.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)

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
                            ScrobbleDayChart(summary: summary, tint: tint)
                                .scrobbleCard()
                        }
                        pageSection("Ora del giorno") {
                            ScrobbleHourRing(byHour: summary.byHour, topHour: summary.topHour, tint: tint)
                                .scrobbleCard()
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
            withAnimation(reduceMotion ? nil : .soft(0.5)) {
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
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ScrobbleStatTile(symbol: "music.note", value: "\(summary.totalScrobbles)", label: "Ascolti",
                             tint: tint, footnote: previous ?? scrobblePlaysPerDay(summary))
            ScrobbleStatTile(symbol: "clock", value: scrobbleDurationShort(summary.listeningTime), label: "Tempo",
                             tint: tint, footnote: scrobbleAveragePerDay(summary))
            ScrobbleStatTile(symbol: "person.2", value: "\(summary.uniqueArtists)", label: "Artisti", tint: tint,
                             footnote: summary.topArtists.first.map { "1° \($0.name)" })
            ScrobbleStatTile(symbol: "music.note.list", value: "\(summary.uniqueTracks)", label: "Brani", tint: tint,
                             footnote: summary.topTracks.first.map { "1° \($0.name)" })
            ScrobbleStatTile(symbol: "flame.fill", value: "\(store.streakDays)", label: "Serie", tint: tint,
                             footnote: "giorni di fila")
            ScrobbleStatTile(symbol: "sun.max.fill", value: peakHour, label: "Ora top", tint: tint,
                             footnote: peakCount)
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
                        // Staggered, but capped so a long list doesn't make the last rows wait.
                        .entrance(.rise, delay: min(Double(index) * 0.035, 0.25))
                    if index < shown.count - 1 {
                        Divider().padding(.leading, 34)
                    }
                }
                if rows.count > 10 {
                    Button(expanded.wrappedValue ? "Mostra meno" : "Mostra tutti (\(rows.count))") {
                        withAnimation(.soft(0.4)) { expanded.wrappedValue.toggle() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 10)
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
            // The bar is the play count against the top of the list; it fades down the list.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.4), tint.opacity(fade(rank))],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, geo.size.width * CGFloat(row.count) / CGFloat(max(maxCount, 1))))
                }
            }
            .frame(height: 6)
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
            Text("\(rank)")
                .font(.system(.title3, design: .rounded, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(medal)
                .frame(width: 22)
        } else {
            Text("\(rank)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
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
            Text(change > 0 ? "▲ \(change)" : change < 0 ? "▼ \(-change)" : "–")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(change > 0 ? Color.green : change < 0 ? Color.red : Color.secondary)
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
                                    ScrobblePulseDot().offset(x: 5, y: -5)
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
                        Text(isNow ? "ora" : scrobbleRelative(listen.date))
                            .font(.caption)
                            .foregroundStyle(isNow ? Color.green : Color.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .contextMenu { trackMenu(listen.itemId, among: recent.map(\.itemId)) }
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
        }
        .foregroundStyle(palette.foreground)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.easeInOut(duration: 0.4), value: palette)
    }

    @ViewBuilder
    private func bandText(_ palette: HeroPalette) -> some View {
        let delta = scrobbleDelta(total: total, previous: previous)
        VStack(alignment: .leading, spacing: 6) {
            Text("Ascolti · \(title)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.secondary)
            Text("\(total)")
                .font(.system(size: compact ? 48 : 60, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.soft(0.6), value: total)
            if let delta {
                HStack(spacing: 4) {
                    Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .foregroundStyle(delta > 0 ? Color.green : delta < 0 ? Color.red : palette.secondary)
                    Text("\(delta > 0 ? "+" : "")\(delta)% rispetto ai \(previousLabel)")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(palette.foreground.opacity(0.15), in: Capsule())
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

/// Listens per day (or per month for all time): gradient bars that grow from zero, the peak and today labelled.
private struct ScrobbleDayChart: View {
    let summary: ScrobbleSummary
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 before the first appearance, 1 after: the bars grow from the baseline.
    @State private var grown = false

    var body: some View {
        // All-time data comes per month, the other periods per day.
        let unit: Calendar.Component = summary.period == .all ? .month : .day
        let peak = summary.byDay.map(\.count).max() ?? 0
        let growth = grown || reduceMotion ? 1.0 : 0.0
        let fill = AnyShapeStyle(LinearGradient(colors: [tint.opacity(0.3), tint.opacity(0.85)],
                                                startPoint: .bottom, endPoint: .top))
        let peakFill = AnyShapeStyle(tint)
        Chart {
            ForEach(summary.byDay.indices, id: \.self) { index in
                let entry = summary.byDay[index]
                let isPeak = entry.count == peak && peak > 0
                let isToday = summary.period != .all && Calendar.current.isDateInToday(entry.day)
                dayBar(day: entry.day, count: entry.count, unit: unit, growth: growth,
                       label: isToday ? "Oggi · \(entry.count)" : (isPeak ? "\(entry.count)" : nil),
                       fill: isPeak || isToday ? peakFill : fill)
            }
        }
        .chartXAxis { dayAxis(for: summary.period) }
        .frame(height: 160)
        .onAppear {
            guard !grown else { return }
            withAnimation(reduceMotion ? nil : .springy(0.9)) { grown = true }
        }
    }

    @ChartContentBuilder
    private func dayBar(day: Date, count: Int, unit: Calendar.Component, growth: Double,
                        label: String?, fill: AnyShapeStyle) -> some ChartContent {
        let bar = BarMark(x: .value("Giorno", day, unit: unit), y: .value("Ascolti", Double(count) * growth))
            .foregroundStyle(fill)
            .cornerRadius(4)
        if let label {
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

/// The 24 hours as a clock ring: each slice fades with its listens, the top hour in the center.
private struct ScrobbleHourRing: View {
    let byHour: [Int]
    let topHour: Int?
    let tint: Color

    var body: some View {
        let peak = max(byHour.max() ?? 0, 1)
        ZStack {
            Chart(byHour.indices, id: \.self) { hour in
                SectorMark(angle: .value("Ora", 1), innerRadius: .ratio(0.6), angularInset: 1.5)
                    .cornerRadius(3)
                    .foregroundStyle(tint.opacity(0.12 + 0.88 * Double(byHour[hour]) / Double(peak)))
            }
            .chartLegend(.hidden)
            .frame(height: 190)

            VStack(spacing: 2) {
                Text(topHour.map { String(format: "%02d:00", $0) } ?? "–")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("ora di punta")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Pieces

private enum ScrobbleRankKind {
    case artist, album, track
}

/// A dense stat on a tinted glass surface: icon and label on one row, the number under it,
/// and an optional small line.
private struct ScrobbleStatTile: View {
    let symbol: String
    let value: String
    let label: String
    let tint: Color
    var footnote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
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
                .contentTransition(.numericText())
                .animation(.soft(0.5), value: value)
            // Always there (blank when empty), so the tiles of a row are the same height.
            Text(footnote ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassEffect(.regular.tint(tint.opacity(0.22)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// "In ascolto ora": a green dot that pulses, off with Reduce Motion.
private struct ScrobblePulseDot: View {
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
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityLabel("In ascolto ora")
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
