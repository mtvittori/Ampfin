
// In Views/Detail/GenreArtistsView.swift
import SwiftUI

struct GenreArtistsView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let genreName: String

    private var filteredArtists: [ArtistItem] {
        let tracksInGenre = viewModel.audioItems.filter { $0.Genres?.contains(genreName) ?? false }
        let artistIdsInGenre = Set(tracksInGenre.compactMap { $0.AlbumArtists?.first?.Id })
        return viewModel.artists.filter { artistIdsInGenre.contains($0.id) }.sorted { $0.Name < $1.Name }
    }

    var body: some View {
        List(filteredArtists) { artist in
            NavigationLink(value: artist) {
                Text(artist.Name)
            }
        }
        .navigationTitle(genreName)
    }
}
