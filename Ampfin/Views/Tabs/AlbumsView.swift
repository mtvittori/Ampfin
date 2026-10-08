// In Views/Tabs/AlbumsView.swift
import SwiftUI

struct AlbumsView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 20)]
    @State private var coverAlbum: AlbumItem?
    @AppStorage("albumsSort") private var sort: AlbumSort = .title
    /// Sorted once per change: the albums are thousands.
    @State private var sorted: [AlbumItem] = []
    /// The first album of each letter, to jump to it.
    @State private var letterTargets: [(letter: String, albumId: String)] = []

    enum AlbumSort: String, CaseIterable, Identifiable {
        case title, artist, added
        var id: String { rawValue }
        var title: String {
            switch self {
            case .title: return "Titolo"
            case .artist: return "Artista"
            case .added: return "Aggiunti di recente"
            }
        }
    }

    private var sortKey: String {
        "\(sort.rawValue)|\(displayedAlbums.count)|\(displayedAlbums.first?.Id ?? "")|\(displayedAlbums.last?.Id ?? "")"
    }

    /// Title or artist A–Z (with the letters on the right), or newest first as before.
    private func resort() {
        let albums = displayedAlbums
        switch sort {
        case .added:
            sorted = albums
            letterTargets = []
            return
        case .title:
            sorted = albums.sorted { $0.Name.localizedStandardCompare($1.Name) == .orderedAscending }
        case .artist:
            sorted = albums.sorted { a, b in
                let byArtist = (a.AlbumArtist ?? "").localizedStandardCompare(b.AlbumArtist ?? "")
                if byArtist != .orderedSame { return byArtist == .orderedAscending }
                return (a.ProductionYear ?? 0) < (b.ProductionYear ?? 0)
            }
        }
        let name: (AlbumItem) -> String = sort == .title ? { $0.Name } : { $0.AlbumArtist ?? "" }
        // Grouped by letter: "#" (numbers, symbols) goes last, as in the index.
        let sections = LetterIndex.sections(sorted, name: name)
        sorted = sections.flatMap(\.items)
        letterTargets = sections.compactMap { section in
            section.items.first.map { (section.letter, $0.Id) }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Ordina per", selection: $sort) {
                ForEach(AlbumSort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
        } label: {
            Label("Ordina per \(sort.title.lowercased())", systemImage: "arrow.up.arrow.down")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }
    
    // If the global search query is present, filter albums accordingly
    private var displayedAlbums: [AlbumItem] {
        // On iPhone the search field filters only the Cerca tab.
        #if os(macOS)
        let query = viewModel.globalSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        let query = ""
        #endif
        if query.isEmpty {
            return viewModel.albums
        } else {
            return viewModel.albums.filter {
                $0.Name.localizedCaseInsensitiveContains(query) ||
                ($0.AlbumArtist ?? "").localizedCaseInsensitiveContains(query) ||
                ($0.Genres?.joined(separator: " ").localizedCaseInsensitiveContains(query) ?? false)
            }
        }
    }

    /// On iPhone the tab's own navigation stack (ContentView) is the only one: a nested
    /// stack here would carry the custom top bar into the album pages it opens.
    @ViewBuilder
    var body: some View {
        #if os(iOS)
        albumsGrid
        #else
        NavigationStack {
            albumsGrid
        }
        #endif
    }

    private var albumsGrid: some View {
        // Usare ScrollView + LazyVGrid evita che l'intera riga di List venga selezionata
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        sortMenu
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    if displayedAlbums.isEmpty {
                        VStack {
                            Text("Nessun album trovato.")
                                .foregroundColor(.secondary)
                                .padding()
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                    } else {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(sorted) { album in
                                NavigationLink(destination: AlbumTracksListView(album: album).zoomDestination("albums-\(album.id)")) {
                                    AlbumGridItemView(album: album, artworkURL: viewModel.artworkURL(for: album.id, size: 300),
                                                      zoomID: "albums-\(album.id)")
                                        .frame(minWidth: 140, minHeight: 160)
                                }
                                .buttonStyle(.pressable)
                                .contextMenu {
                                    AlbumQueueMenuItems(album: album)
                                    Divider()
                                    Button("Cambia copertina", systemImage: "photo") { coverAlbum = album }
                                }
                                .gridSettle()
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 170) // lascia spazio per mini player overlay
                    }
                }
                .frame(maxWidth: .infinity)
            }
            #if os(iOS)
            .hidesMiniPlayerOnScroll()
            #endif
            .refreshable {
                await LibraryRefresh.shared.run { await viewModel.fetchAllLibraryData() }
            }
            .libraryRefreshBanner()
            .letterScrubber(letters: letterTargets.map(\.letter)) { letter in
                if let target = letterTargets.first(where: { $0.letter == letter }) {
                    proxy.scrollTo(target.albumId, anchor: .top)
                }
            }
        }
        .task(id: sortKey) { resort() }
        .background(Color.clear)
        .navigationTitle("Album")
        // Manteniamo la navigationDestination per compatibilità con altre parti dell'app
        .navigationDestination(for: AlbumItem.self) { album in
            AlbumTracksListView(album: album)
        }
        .sheet(item: $coverAlbum) { album in
            AlbumCoverPicker(album: album)
                .environmentObject(viewModel)
        }
    }
}
