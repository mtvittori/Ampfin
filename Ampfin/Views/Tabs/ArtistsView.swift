// In Views/Tabs/ArtistsView.swift
import SwiftUI

struct ArtistsView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    @State private var path = NavigationPath()
    /// Artist whose long-press menu asked to merge others into it.
    @State private var mergeTarget: ArtistItem?

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
}
