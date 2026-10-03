// In Views/Tabs/ArtistsView.swift
import SwiftUI

struct ArtistsView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var colorManager = AccentColorManager.shared
    @Environment(\.zunePivotHeaderHeight) private var pivotHeader

    /// Row at the top of the list; its artist's photo fills the background.
    @State private var scrolledID: String?
    @State private var backdropArtist: ArtistItem?
    @State private var path = NavigationPath()
    /// Artist whose long-press menu asked to merge others into it.
    @State private var mergeTarget: ArtistItem?

    // Use global search query to filter artists
    private var displayedArtists: [ArtistItem] {
        let query = viewModel.globalSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return viewModel.artists
        } else {
            return viewModel.artists.filter {
                $0.Name.localizedCaseInsensitiveContains(query) ||
                ($0.Genres?.joined(separator: " ").localizedCaseInsensitiveContains(query) ?? false)
            }
        }
    }

    var body: some View {
        // In the pivot the root owns the navigation stack and its destinations.
        if pivotHeader > 0 {
            zuneList
        } else {
            stackBody
        }
    }

    @ViewBuilder
    private var stackBody: some View {
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
        Group {
            if colorManager.zuneStyleEnabled {
                zuneList
            } else {
                classicList
            }
        }
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

    private var classicList: some View {
        List(displayedArtists) { artist in
            NavigationLink(value: artist) {
                Text(artist.Name)
            }
            .mergeArtistMenu(artist, target: $mergeTarget)
        }
        .navigationTitle("Artisti")
        .sheet(item: $mergeTarget) { artist in
            MergeArtistsSheet(main: artist)
                .environmentObject(viewModel)
        }
    }

    // MARK: - Zune

    private var zuneList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ZunePageTitle(text: "artisti")
                    .id("header")

                ForEach(letterGroups, id: \.letter) { group in
                    letterTile(group.letter)
                        .id("letter-\(group.letter)")

                    ForEach(group.artists) { artist in
                        NavigationLink(value: artist) {
                            artistRow(artist)
                        }
                        .buttonStyle(.plain)
                        .mergeArtistMenu(artist, target: $mergeTarget)
                        .id(artist.Id)
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 20)
            .padding(.bottom, 120)
        }
        .scrollPosition(id: $scrolledID, anchor: .top)
        .sheet(item: $mergeTarget) { artist in
            MergeArtistsSheet(main: artist)
                .environmentObject(viewModel)
        }
        .zuneBackdrop(urls: backdropArtist.map { viewModel.artistImageURLs(for: $0) } ?? [], dim: 0.55)
        #if os(iOS)
        .hidesMiniPlayerOnScroll()
        #endif
        .zuneChrome()
        // Wait for the list to settle before swapping the photo, so a fast fling
        // doesn't download every artist it passes.
        .task(id: scrolledID) {
            if backdropArtist != nil {
                try? await Task.sleep(for: .milliseconds(400))
                if Task.isCancelled { return }
            }
            backdropArtist = artistForBackdrop()
        }
        .onChange(of: viewModel.artists.count) {
            if backdropArtist == nil { backdropArtist = artistForBackdrop() }
        }
    }

    private func artistRow(_ artist: ArtistItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(artist.Name.lowercased())
                .font(.zune(30, .light, relativeTo: .title))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let genres = artist.Genres, !genres.isEmpty {
                Text(genres.prefix(2).joined(separator: " · ").lowercased())
                    .font(.zune(14, .regular, relativeTo: .caption))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// Accent-colored square with the initial, like the Zune jump list.
    private func letterTile(_ letter: String) -> some View {
        Text(letter.lowercased())
            .font(.zune(34, .light, relativeTo: .title))
            .foregroundStyle(.white)
            .frame(width: 54, height: 54, alignment: .bottomLeading)
            .padding(.leading, 6)
            .padding(.bottom, 2)
            .frame(width: 60, height: 60, alignment: .bottomLeading)
            .background(Color.accentColor)
            .padding(.top, 18)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private struct LetterGroup {
        let letter: String
        var artists: [ArtistItem]
    }

    /// Consecutive artists grouped by initial; digits and symbols go under "#".
    private var letterGroups: [LetterGroup] {
        var groups: [LetterGroup] = []
        for artist in displayedArtists {
            let letter = Self.initial(of: artist.Name)
            if groups.last?.letter == letter {
                groups[groups.count - 1].artists.append(artist)
            } else {
                groups.append(LetterGroup(letter: letter, artists: [artist]))
            }
        }
        return groups
    }

    /// Initial as the server sorts it: "The 1975" files under "#", not "t".
    private static func initial(of name: String) -> String {
        var key = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        if key.hasPrefix("the ") { key.removeFirst(4) }
        guard let first = key.first,
              first.isLetter else { return "#" }
        return String(first).uppercased()
    }

    /// The artist at the top of the list, or the first one under a letter tile.
    private func artistForBackdrop() -> ArtistItem? {
        let artists = displayedArtists
        guard let id = scrolledID else { return artists.first }
        if let artist = artists.first(where: { $0.Id == id }) { return artist }
        if id.hasPrefix("letter-") {
            let letter = String(id.dropFirst("letter-".count))
            return artists.first { Self.initial(of: $0.Name) == letter }
        }
        return artists.first
    }
}
