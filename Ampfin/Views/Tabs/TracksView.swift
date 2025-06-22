import SwiftUI

struct TracksView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @State private var searchText = ""

    var filteredTracks: [AudioItem] {
        if searchText.isEmpty {
            return viewModel.audioItems
        } else {
            // ... (logica di filtro invariata) ...
            return viewModel.audioItems.filter {
                $0.Name.localizedCaseInsensitiveContains(searchText) ||
                ($0.mainArtistName ?? "").localizedCaseInsensitiveContains(searchText) ||
                ($0.Album ?? "").localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // ... (Barra di ricerca invariata) ...
            List(filteredTracks) { item in
                let artworkURL = viewModel.artworkURL(for: item.id, size: 80)
                         // Controlla se l'item attuale è quello in riproduzione
                let isPlaying = (viewModel.currentlyPlayingItem?.id == item.id)
                TrackRowView(item: item, artworkURL: artworkURL, isPlaying: isPlaying)
                                .onTapGesture {
                                    viewModel.playerManager.play(item: item, in: filteredTracks)
                                }
            }
            .listStyle(.plain)
        }
        .navigationTitle("Brani")
        .toolbar {
            ToolbarItem {
                Button("Logout") { viewModel.logout() }
            }
        }
    }
}
