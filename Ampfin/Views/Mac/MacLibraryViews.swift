// MacLibraryViews.swift
// The library sections for the Mac: the grid of albums, the grid of artists, songs.

#if os(macOS)
import SwiftUI

// MARK: - Albums

struct MacAlbumsView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    private enum Sort: String, CaseIterable, Identifiable {
        case title = "Titolo", artist = "Artista", added = "Aggiunti di recente", year = "Anno"
        var id: String { rawValue }
    }
    @AppStorage("macAlbumSort") private var sortRaw = Sort.title.rawValue

    private var sort: Sort { Sort(rawValue: sortRaw) ?? .title }

    private var albums: [AlbumItem] {
        let query = viewModel.globalSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = query.isEmpty ? viewModel.albums : viewModel.albums.filter {
            $0.Name.localizedCaseInsensitiveContains(query) || ($0.AlbumArtist ?? "").localizedCaseInsensitiveContains(query)
        }
        switch sort {
        case .title: return all.sorted { $0.Name.localizedStandardCompare($1.Name) == .orderedAscending }
        case .artist:
            return all.sorted {
                let a = $0.AlbumArtist ?? "", b = $1.AlbumArtist ?? ""
                return a == b ? $0.Name.localizedStandardCompare($1.Name) == .orderedAscending
                              : a.localizedStandardCompare(b) == .orderedAscending
            }
        case .added: return all.sorted { ($0.dateAddedDate ?? .distantPast) > ($1.dateAddedDate ?? .distantPast) }
        case .year: return all.sorted { ($0.ProductionYear ?? 0) > ($1.ProductionYear ?? 0) }
        }
    }

    var body: some View {
        let shown = albums
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                MacPageHeader(title: "Album", subtitle: shown.isEmpty ? nil : "\(shown.count.formatted()) album")
                LazyVGrid(columns: macAlbumColumns, alignment: .leading, spacing: 26) {
                    ForEach(shown) { MacAlbumCard(album: $0) }
                }
            }
            .padding(28)
        }
        .macScrollTracking()
        .navigationTitle("Album")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Ordina per", selection: $sortRaw) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.menu)
            }
        }
    }
}

// MARK: - Recently added

struct MacRecentView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    var body: some View {
        let albums = Array(viewModel.albums
            .sorted { ($0.dateAddedDate ?? .distantPast) > ($1.dateAddedDate ?? .distantPast) }
            .prefix(200))
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                MacPageHeader(title: "Aggiunti di recente", subtitle: albums.isEmpty ? nil : "\(albums.count) album")
                LazyVGrid(columns: macAlbumColumns, alignment: .leading, spacing: 26) {
                    ForEach(albums) { MacAlbumCard(album: $0) }
                }
            }
            .padding(28)
        }
        .macScrollTracking()
        .navigationTitle("Aggiunti di recente")
    }
}

// MARK: - Artists

struct MacArtistsView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @State private var mergeTarget: ArtistItem?

    private var artists: [ArtistItem] {
        let query = viewModel.globalSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? viewModel.artists : viewModel.artists.filter {
            $0.Name.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let shown = artists
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
            MacPageHeader(title: "Artisti", subtitle: shown.isEmpty ? nil : "\(shown.count.formatted()) artisti")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 24, alignment: .top)],
                      alignment: .leading, spacing: 26) {
                ForEach(shown) { artist in
                    NavigationLink(value: artist) {
                        VStack(spacing: 10) {
                            MacArtistAvatar(artist: artist)
                            Text(artist.Name)
                                .font(.callout.weight(.medium))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .mergeArtistMenu(artist, target: $mergeTarget)
                }
            }
            }
            .padding(28)
        }
        .macScrollTracking()
        .navigationTitle("Artisti")
        .sheet(item: $mergeTarget) { artist in
            MergeArtistsSheet(main: artist)
                .environmentObject(viewModel)
        }
    }
}

// MARK: - Songs

struct MacTracksView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    private var tracks: [AudioItem] {
        let query = viewModel.globalSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.audioItems }
        return viewModel.audioItems.filter {
            $0.Name.localizedCaseInsensitiveContains(query) ||
            ($0.mainArtistName ?? "").localizedCaseInsensitiveContains(query) ||
            ($0.Album ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let shown = tracks
        VStack(spacing: 0) {
            MacPageHeader(title: "Brani", subtitle: shown.isEmpty ? nil : "\(shown.count.formatted()) brani")
                .padding(.horizontal, 28)
                .padding(.top, 14)
                .padding(.bottom, 10)
            MacSongsTable(tracks: shown)
                .macScrollTracking()
        }
        .navigationTitle("Brani")
    }
}
#endif

#if os(macOS)
// MARK: - Genres

struct MacGenresView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    private var genres: [(name: String, count: Int)] {
        let counts = Dictionary(viewModel.albums.flatMap { $0.Genres ?? [] }.map { ($0, 1) }, uniquingKeysWith: +)
        return viewModel.allAvailableGenres.map { ($0, counts[$0] ?? 0) }
    }

    /// The same genre always gets the same color.
    private func color(for name: String) -> Color {
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.62)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
            MacPageHeader(title: "Generi", subtitle: "\(genres.count.formatted()) generi")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 16)], spacing: 16) {
                ForEach(genres, id: \.name) { genre in
                    NavigationLink(value: genre.name) {
                        VStack(alignment: .leading, spacing: 2) {
                            Spacer(minLength: 0)
                            Text(genre.name).font(.title3.weight(.bold)).lineLimit(2)
                            if genre.count > 0 {
                                Text(genre.count == 1 ? "1 album" : "\(genre.count) album")
                                    .font(.callout).opacity(0.8)
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                        .background(
                            LinearGradient(colors: [color(for: genre.name), color(for: genre.name).opacity(0.7)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            }
            .padding(28)
        }
        .macScrollTracking()
        .navigationTitle("Generi")
    }
}

struct MacGenrePage: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let genreName: String

    var body: some View {
        let albums = viewModel.albums.filter { $0.Genres?.contains(genreName) ?? false }
        let artists = viewModel.artists.filter { $0.Genres?.contains(genreName) ?? false }
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                MacPageHeader(title: genreName)
                if !albums.isEmpty {
                    MacSectionTitle(title: "Album")
                    LazyVGrid(columns: macAlbumColumns, alignment: .leading, spacing: 26) {
                        ForEach(albums) { MacAlbumCard(album: $0) }
                    }
                }
                if !artists.isEmpty {
                    MacSectionTitle(title: "Artisti")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 24, alignment: .top)],
                              alignment: .leading, spacing: 24) {
                        ForEach(artists) { artist in
                            NavigationLink(value: artist) {
                                VStack(spacing: 8) {
                                    MacArtistAvatar(artist: artist)
                                    Text(artist.Name).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(28)
        }
        .macScrollTracking()
        .navigationTitle(genreName)
    }
}

// MARK: - Favorites

struct MacFavoritesView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @State private var selection: String?

    var body: some View {
        let tracks = viewModel.favoriteTracks
        let albums = viewModel.favoriteAlbums

        if tracks.isEmpty && albums.isEmpty {
            ContentUnavailableView("Nessun preferito", systemImage: "heart",
                                   description: Text("Segna con il cuore un album o un brano per ritrovarli qui."))
                .navigationTitle("Preferiti")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    MacPageHeader(title: "Preferiti")
                    if !albums.isEmpty {
                        MacSectionTitle(title: "Album")
                        LazyVGrid(columns: macAlbumColumns, alignment: .leading, spacing: 26) {
                            ForEach(albums) { MacAlbumCard(album: $0) }
                        }
                    }
                    if !tracks.isEmpty {
                        HStack {
                            MacSectionTitle(title: "Brani")
                            Spacer()
                            MacPlayButtons(tracks: tracks)
                        }
                        LazyVStack(spacing: 0) {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                MacTrackRow(track: track, number: nil, queue: tracks, detail: track.Album,
                                            showsCover: true, striped: index.isMultiple(of: 2), selection: $selection)
                            }
                        }
                    }
                }
                .padding(28)
            }
            .macScrollTracking()
            .navigationTitle("Preferiti")
        }
    }
}
#endif
