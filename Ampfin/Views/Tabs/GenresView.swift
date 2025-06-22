// In Views/Tabs/GenresView.swift
import SwiftUI

struct GenresView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    var body: some View {
        NavigationStack {
            List(viewModel.allAvailableGenres, id: \.self) { genreName in
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
