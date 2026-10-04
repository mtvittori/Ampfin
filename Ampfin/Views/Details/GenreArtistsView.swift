import SwiftUI

struct GenreArtistsView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let genreName: String

    private var filteredArtists: [ArtistItem] {
        viewModel.artists.filter { $0.Genres?.contains(genreName) ?? false }
    }

    private var filteredAlbums: [AlbumItem] {
        viewModel.albums.filter { $0.Genres?.contains(genreName) ?? false }
    }

    var body: some View {
        #if os(macOS)
        MacGenrePage(genreName: genreName)
        #else
        phoneBody
        #endif
    }

    private var phoneBody: some View {
        ScrollView {
            if !filteredAlbums.isEmpty {
                Text("Album").font(.title2).padding(.leading)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 20)]) {
                    ForEach(filteredAlbums) { album in
                        let artworkURL = viewModel.artworkURL(for: album.id, size: 300)
                        NavigationLink(destination: AlbumTracksListView(album: album)) {
                            AlbumGridItemView(album: album, artworkURL: artworkURL)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }

            if !filteredArtists.isEmpty {
                Text("Artisti").font(.title2).padding(.leading)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 20)]) {
                    ForEach(filteredArtists) { artist in
                        let artworkURL = viewModel.artworkURL(for: artist.id, size: 300)
                        NavigationLink(destination: ArtistAlbumsView(artist: artist)) {
                            ArtistGridItemView(artist: artist, artworkURL: artworkURL)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
        .navigationTitle(genreName)
    }
}
