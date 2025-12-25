// In Views/Tabs/ArtistsView.swift
import SwiftUI

struct ArtistsView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

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
        NavigationStack {
            List(displayedArtists) { artist in
                NavigationLink(destination: ArtistAlbumsView(artist: artist)) {
                    Text(artist.Name)
                }
            }
            .navigationTitle("Artisti")
            .navigationDestination(for: ArtistItem.self) { artist in
                ArtistAlbumsView(artist: artist)
            }
            .navigationDestination(for: AlbumItem.self) { album in
                AlbumTracksListView(album: album)
            }
        }
    }
}
