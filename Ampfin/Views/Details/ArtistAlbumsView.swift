// In Views/Detail/ArtistAlbumsView.swift
import SwiftUI

struct ArtistAlbumsView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let artist: ArtistItem

    private var filteredAlbums: [AlbumItem] {
        viewModel.albums.filter { $0.AlbumArtist == artist.Name }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 20)]) {
                ForEach(filteredAlbums) { album in
                    let artworkURL = viewModel.artworkURL(for: album.id, size: 300)
                    NavigationLink(destination: AlbumTracksListView(album: album)) {
                        AlbumGridItemView(album: album, artworkURL: artworkURL)
                            .drawingGroup()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(.clear) // Aggiungi anche qui!
        .navigationTitle(artist.Name)
    }
}
