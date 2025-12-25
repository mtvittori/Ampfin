// In Views/Tabs/GenresView.swift
import SwiftUI

struct GenresView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    // Apply global search query to filter the genre list
    private var displayedGenres: [String] {
        let q = viewModel.globalSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            return viewModel.allAvailableGenres
        } else {
            return viewModel.allAvailableGenres.filter { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        NavigationStack {
            List(displayedGenres, id: \.self) { genreName in
                NavigationLink(genreName, value: genreName)
            }
            .navigationTitle("Generi")
            .navigationDestination(for: String.self) { genreName in
                GenreArtistsView(genreName: genreName)
            }
            .navigationDestination(for: ArtistItem.self) { artist in
                ArtistAlbumsView(artist: artist)
            }
            .navigationDestination(for: AlbumItem.self) { album in
                AlbumTracksListView(album: album)
            }
        }
    }
}
