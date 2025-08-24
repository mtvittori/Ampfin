// In Views/Tabs/ArtistsView.swift
import SwiftUI

struct ArtistsView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    var body: some View {
        NavigationStack {
            List(viewModel.artists) { artist in
                NavigationLink(destination: ArtistAlbumsView(artist: artist)) {
                    Text(artist.Name)
                }
            }
            .navigationTitle("Artisti")
            .navigationDestination(for: ArtistItem.self) { artist in
                ArtistAlbumsView(artist: artist)
            }
            .navigationDestination(for: AlbumItem.self) { album in
                // Aggiungiamo questa destinazione per navigare dall'album dell'artista al dettaglio tracce
                AlbumTracksListView(album: album)
            }
        }
    }
}
