// In Views/Tabs/ArtistsView.swift
import SwiftUI

struct ArtistsView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    @State private var path = NavigationPath()
    /// Artist whose long-press menu asked to merge others into it.
    @State private var mergeTarget: ArtistItem?

    @State private var sections: [LetterSection<ArtistItem>] = []
    /// The flat rows of the A–Z style, built with the sections, not at every redraw.
    @State private var rows: [LetterRow<ArtistItem>] = []
    @AppStorage(LetterIndexStyle.storageKey) private var indexStyle = LetterIndexStyle.classic.rawValue
    private var classicIndex: Bool { indexStyle == LetterIndexStyle.classic.rawValue }

    private func artistRow(_ artist: ArtistItem) -> some View {
        NavigationLink(value: artist) {
            // One line, so every row has the same height: with rows of different heights
            // the list re-measured them on the way back from an artist and slid down to
            // find its place again.
            Text(artist.Name)
                .lineLimit(1)
        }
        .mergeArtistMenu(artist, target: $mergeTarget)
    }

    private var sectionsKey: String {
        "\(displayedArtists.count)|\(displayedArtists.first?.Id ?? "")|\(displayedArtists.last?.Id ?? "")"
    }

    // Use global search query to filter artists
    private var displayedArtists: [ArtistItem] {
        // On iPhone the search field filters only the Cerca tab.
        #if os(macOS)
        let query = viewModel.globalSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        let query = ""
        #endif
        if query.isEmpty {
            return viewModel.artists
        } else {
            return viewModel.artists.filter {
                $0.Name.localizedCaseInsensitiveContains(query) ||
                ($0.Genres?.joined(separator: " ").localizedCaseInsensitiveContains(query) ?? false)
            }
        }
    }

    @ViewBuilder
    var body: some View {
        #if os(iOS)
        // On iPhone the tab's own navigation stack (ContentView) is the only one: a nested
        // stack here would carry the custom top bar into the pages it opens.
        artistsContent
            #if DEBUG
            .navigationDestination(item: $testArtist) { artist in ArtistAlbumsView(artist: artist) }
            .navigationDestination(item: $testAlbum) { album in AlbumTracksListView(album: album) }
            .task(id: viewModel.artists.count) { openTestPage() }
            #endif
        #else
        NavigationStack(path: $path) {
            artistsContent
        }
        #endif
    }

    private var artistsContent: some View {
        artistList
        .refreshable {
            await viewModel.fetchAllLibraryData()
        }
        .navigationDestination(for: ArtistItem.self) { artist in
            ArtistAlbumsView(artist: artist)
        }
        .navigationDestination(for: AlbumItem.self) { album in
            AlbumTracksListView(album: album)
        }
    }

    #if DEBUG
    @State private var testArtist: ArtistItem?
    @State private var testAlbum: AlbumItem?

    /// Test-only: `-provaArtista <name>` opens that artist's page, `-provaAlbum <name>` an album.
    private func openTestPage() {
        guard testArtist == nil, testAlbum == nil else { return }
        if let name = UserDefaults.standard.string(forKey: "provaArtista") {
            testArtist = viewModel.artists.first { $0.Name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        } else if let name = UserDefaults.standard.string(forKey: "provaAlbum") {
            testAlbum = viewModel.albums.first { $0.Name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        }
    }
    #endif

    private var artistList: some View {
        // Grouped by letter, with the A–Z strip on the right to jump.
        ScrollViewReader { proxy in
            List {
                if classicIndex {
                    // iOS's own index: sections with their letter, the smoothest to scroll.
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { artist in
                                artistRow(artist)
                            }
                        } header: {
                            Text(section.letter)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        .sectionIndexLabel(section.letter)
                    }
                } else {
                    ForEach(rows) { row in
                        switch row {
                        case .letter(let letter): LetterHeaderRow(letter: letter)
                        case .item(let artist): artistRow(artist)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .systemLetterIndex(classicIndex)
            .letterScrubber(letters: classicIndex ? [] : sections.map(\.letter)) { letter in
                proxy.scrollTo(LetterIndex.rowId(letter), anchor: .top)
            }
        }
        // Grouped once per change, not at every redraw.
        .task(id: sectionsKey) {
            let grouped = LetterIndex.sections(displayedArtists, name: \.Name)
            sections = grouped
            rows = LetterRow.rows(grouped)
        }
        .navigationTitle("Artisti")
        .sheet(item: $mergeTarget) { artist in
            MergeArtistsSheet(main: artist)
                .environmentObject(viewModel)
        }
    }
}
